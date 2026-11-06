#!/usr/bin/env python3
"""tests/read-gate.py — which reads in bin/ and hooks/ can fail and still reach a state change?

A script of this tree reads state in many ways: command substitutions, readers (cat, awk, stat, date, ps ...), redirected
input, metadata tests, sourced files. A read that fails and is not noticed can be taken for "nothing there" and then moves a
cursor, drops a registry row or skips a reminder. This gate parses every script into a tree (a closed subset of Bash, anything
else is refused), lists every read occurrence, and says for each one what happens to its failure:

  OK:<idiom>     the failure reaches a refusal (exit, return N, a function that always exits)
  LISTED:<code>  not an idiom, but an exact entry in tests/read-gate.allow with a reason the scanner itself can check
  UNLISTED:<why> anything else

Idioms (the grammar is this file; the fixtures in tests/read-gate-fixtures/ and --self-test pin it):
  I1  checked capture   x=$(cmd) || REFUSE, or  if ! x=$(cmd); then REFUSE; fi  (whole assignment, one substitution, no
                        declaration builtin, every command of the substitution on the failure path)
  I2  pipeline          a pipeline whose stages are protected by `set -o pipefail` in the same substitution or subshell
  I3  saved status      x=$(cmd); rc=$?  then, as the very next statements, a test of $rc whose failure branch refuses
  I4  snapshot          a here-string loop over a variable that an I1 capture filled and nothing reassigned
  (I5 three outcomes: absent / unreadable / present needs an errno-aware helper. None exists in this tree, so the gate
   refuses the shape; the repairs add the helper and the idiom together.)
  CK  checked command   a reader or helper called as `cmd || REFUSE` or as the condition of a refusing if
Allow-file reasons (each one has a closed contract below): D K H M X P V C O.

Modes: report (default, exit 0 whatever the findings), --enforce (exit 1 on any unlisted, dead, invalid or ambiguous
entry), --self-test (fixtures, mutants, counterexamples; exit 1 on any failed expectation). Exit 2 is a tool error: an
unparsable script, no files, an unreadable file. Python 3.8+, standard library only.
"""
import argparse
import hashlib
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile

# ----------------------------------------------------------------------------------------------------------------------
# Parser: a closed subset of Bash. Anything outside it raises ParseError, which is a tool error, never a pass.
# ----------------------------------------------------------------------------------------------------------------------


class ParseError(Exception):
    pass


class Node:
    def __init__(self, k, start, end=None, **kw):
        self.k = k
        self.start = start
        self.end = end
        self.parent = None
        self.__dict__.update(kw)

    def kids(self):
        out = []

        def walk(v):
            if isinstance(v, Node):
                out.append(v)
            elif isinstance(v, (list, tuple)):
                for x in v:
                    walk(x)
        for key, v in list(self.__dict__.items()):
            if key in ('k', 'start', 'end', 'parent', 'src'):
                continue
            walk(v)
        return out


DELIM = set(' \t\n;&|()<>')
ASSIGN_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]\n]*\])?\+?=')
FUNC_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*[ \t]*\([ \t]*\)')
REDIR_RE = re.compile(r'([0-9]*)(<<<|<<-|<<|<>|<&|>&|>>|>\||&>|<|>)')


class Parser:
    def __init__(self, src):
        self.s = src
        self.n = len(src)
        self.i = 0
        self.pending = []
        self.line_starts = [0] + [m.end() for m in re.finditer(r'\n', src)]

    def line(self, off):
        lo, hi = 0, len(self.line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.line_starts[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def err(self, msg, off=None):
        raise ParseError('line %d: %s' % (self.line(self.i if off is None else off), msg))

    # --- whitespace, newlines, heredoc bodies ---
    def skip_blank(self):
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in ' \t':
                self.i += 1
            elif c == '\\' and self.i + 1 < n and s[self.i + 1] == '\n':
                self.i += 2
            else:
                break

    def newline(self):
        self.i += 1
        while self.pending:
            delim, quoted, strip, node = self.pending.pop(0)
            body_start = self.i
            lines = []
            while True:
                if self.i >= self.n:
                    self.err('heredoc %s is not closed' % delim)
                j = self.s.find('\n', self.i)
                j = self.n if j < 0 else j
                ln = self.s[self.i:j]
                self.i = min(j + 1, self.n)
                if (ln.lstrip('\t') if strip else ln) == delim:
                    break
                lines.append(ln)
            node.body = '\n'.join(lines)
            node.parts = []
            if not quoted:
                sub = Parser(node.body + '\n')
                sub.s = node.body
                sub.n = len(node.body)
                try:
                    node.parts = sub.parse_dq_text()
                except ParseError as e:
                    self.err('heredoc body: %s' % e, body_start)
                # nested nodes keep body-relative offsets: they belong to the heredoc, not to the script text
                for p in node.parts:
                    if isinstance(p, Node):
                        shift(p, body_start)

    def skip_ws(self, nl=True):
        s = self.s
        while self.i < self.n:
            c = s[self.i]
            if c in ' \t':
                self.i += 1
            elif c == '\\' and self.i + 1 < self.n and s[self.i + 1] == '\n':
                self.i += 2
            elif c == '\n' and nl:
                self.newline()
            elif c == '#':
                while self.i < self.n and s[self.i] != '\n':
                    self.i += 1
            else:
                break

    # --- lists ---
    def peek_bare(self):
        j = self.i
        while j < self.n and self.s[j] not in DELIM and self.s[j] not in '"\'$`\\':
            j += 1
        return self.s[self.i:j]

    def at_term(self, terms):
        s, i = self.s, self.i
        if i >= self.n:
            return True
        if ')' in terms and s[i] == ')':
            return True
        if ';;' in terms and (s.startswith(';;', i) or s.startswith(';&', i)):
            return True
        w = self.peek_bare()
        if w in terms and w not in ('{',) and w != '':
            return True
        if '}' in terms and s[i] == '}' and (i + 1 >= self.n or s[i + 1] in DELIM):
            return True
        return False

    def parse_list(self, terms):
        start = self.i
        items = []
        while True:
            self.skip_ws()
            if self.at_term(terms):
                break
            if self.s[self.i] in ';&|)':
                self.err('unexpected %r' % self.s[self.i])
            items.append(self.parse_andor())
            self.skip_blank()
            if self.i < self.n:
                c = self.s[self.i]
                if c == ';' and not self.s.startswith(';;', self.i) and not self.s.startswith(';&', self.i):
                    self.i += 1
                elif c == '&' and not self.s.startswith('&&', self.i):
                    items[-1].bg = True     # runs in the background: its status and its exit never reach this shell
                    self.i += 1
        return Node('list', start, self.i, items=items)

    def parse_andor(self):
        start = self.i
        parts = [self.parse_pipeline()]
        ops = []
        while True:
            self.skip_blank()
            if self.s.startswith('&&', self.i) or self.s.startswith('||', self.i):
                ops.append(self.s[self.i:self.i + 2])
                self.i += 2
                self.skip_ws()
                parts.append(self.parse_pipeline())
            else:
                break
        end = self.i
        while end > start and self.s[end - 1] in ' \t\n':
            end -= 1
        return Node('andor', start, end, parts=parts, ops=ops)

    def parse_pipeline(self):
        start = self.i
        self.skip_blank()
        neg = False
        if self.s.startswith('!', self.i) and self.i + 1 < self.n and self.s[self.i + 1] in ' \t':
            neg = True
            self.i += 1
            self.skip_blank()
        cmds = [self.parse_command()]
        while True:
            self.skip_blank()
            if self.s.startswith('||', self.i):
                break
            if self.i < self.n and self.s[self.i] == '|':
                self.i += 2 if self.s.startswith('|&', self.i) else 1      # |& is a pipe that also carries stderr
                self.skip_ws()
                cmds.append(self.parse_command())
            else:
                break
        return Node('pipe', start, self.i, cmds=cmds, neg=neg)

    # --- commands ---
    def parse_command(self):
        self.skip_blank()
        s, i = self.s, self.i
        if i >= self.n:
            self.err('a command was expected')
        w = self.peek_bare()
        if s.startswith('((', i):
            self.err('(( )) commands are outside the supported subset')
        if s[i] == '(':
            self.i += 1
            body = self.parse_list({')'})
            self.expect(')')
            return self.finish_compound(Node('subshell', i, self.i, body=body))
        if w == 'if':
            return self.parse_if()
        if w in ('while', 'until'):
            self.i += len(w)
            cond = self.parse_list({'do'})
            self.expect_word('do')
            body = self.parse_list({'done'})
            self.expect_word('done')
            return self.finish_compound(Node('while', i, self.i, until=(w == 'until'), cond=cond, body=body))
        if w == 'for':
            return self.parse_for()
        if w == 'case':
            return self.parse_case()
        if s[i] == '{' and (i + 1 < self.n and s[i + 1] in ' \t\n'):
            self.i += 1
            body = self.parse_list({'}'})
            self.expect('}')
            return self.finish_compound(Node('group', i, self.i, body=body))
        if w == 'function':
            self.i += len('function')
            self.skip_blank()
            m = re.compile(r'[A-Za-z_][A-Za-z0-9_]*').match(s, self.i)
            if not m:
                self.err('function: a name was expected')
            name = m.group(0)
            self.i = m.end()
            self.skip_blank()
            if s.startswith('(', self.i):
                self.i += 1
                self.skip_blank()
                self.expect(')')
            self.skip_ws()
            body = self.parse_command()
            if body.k not in ('group', 'subshell', 'if', 'while', 'case'):
                self.err('function body must be a compound command')
            return Node('func', i, self.i, name=name, body=body)
        if w in ('then', 'elif', 'else', 'fi', 'do', 'done', 'esac', 'in', 'select', 'coproc', 'time'):
            self.err('unexpected or unsupported reserved word %r' % w)
        m = FUNC_RE.match(s, i)
        if m and w:
            name = s[i:m.end()].split('(')[0].strip()
            self.i = m.end()
            self.skip_ws()
            body = self.parse_command()
            if body.k not in ('group', 'subshell', 'if', 'while', 'case'):
                self.err('function body must be a compound command')
            return Node('func', i, self.i, name=name, body=body)
        return self.parse_simple()

    def expect(self, ch):
        self.skip_ws()
        if not self.s.startswith(ch, self.i):
            self.err('expected %r' % ch)
        self.i += len(ch)

    def expect_word(self, w):
        self.skip_ws()
        if self.peek_bare() != w:
            self.err('expected %r' % w)
        self.i += len(w)

    def finish_compound(self, node):
        node.redirs = self.parse_redirs()
        node.end = self.i
        return node

    def parse_redirs(self):
        out = []
        while True:
            self.skip_blank()
            if self.i < self.n and (REDIR_RE.match(self.s, self.i) and not self.s.startswith('<(', self.i)):
                out.append(self.parse_redir())
            else:
                break
        return out

    def parse_if(self):
        start = self.i
        self.i += 2
        clauses = []
        cond = self.parse_list({'then'})
        self.expect_word('then')
        body = self.parse_list({'elif', 'else', 'fi'})
        clauses.append((cond, body))
        els = None
        while True:
            self.skip_ws()
            w = self.peek_bare()
            if w == 'elif':
                self.i += 4
                cond = self.parse_list({'then'})
                self.expect_word('then')
                body = self.parse_list({'elif', 'else', 'fi'})
                clauses.append((cond, body))
            elif w == 'else':
                self.i += 4
                els = self.parse_list({'fi'})
            elif w == 'fi':
                self.i += 2
                break
            else:
                self.err('if is not closed')
        return self.finish_compound(Node('if', start, self.i, clauses=clauses, els=els))

    def parse_for(self):
        start = self.i
        self.i += 3
        self.skip_blank()
        m = re.compile(r'[A-Za-z_][A-Za-z0-9_]*').match(self.s, self.i)
        if not m:
            self.err('for needs a variable name')
        var = m.group(0)
        self.i = m.end()
        self.skip_blank()
        words = []
        if self.peek_bare() == 'in':
            self.i += 2
            while True:
                self.skip_blank()
                if self.i >= self.n or self.s[self.i] in ';\n':
                    break
                words.append(self.parse_word())
        self.skip_blank()
        if self.i < self.n and self.s[self.i] == ';':
            self.i += 1
        self.expect_word('do')
        body = self.parse_list({'done'})
        self.expect_word('done')
        return self.finish_compound(Node('for', start, self.i, var=var, words=words, body=body))

    def parse_case(self):
        start = self.i
        self.i += 4
        self.skip_blank()
        word = self.parse_word()
        self.expect_word('in')
        arms = []
        while True:
            self.skip_ws()
            if self.peek_bare() == 'esac':
                self.i += 4
                break
            if self.i >= self.n:
                self.err('case is not closed')
            if self.s[self.i] == '(':
                self.i += 1
            pats = []
            while True:
                self.skip_blank()
                pats.append(self.parse_pattern())
                self.skip_blank()
                if self.s[self.i] == '|':
                    self.i += 1
                    continue
                if self.s[self.i] == ')':
                    self.i += 1
                    break
                self.err('bad case pattern')
            body = self.parse_list({';;', 'esac'})
            term = None
            if self.s.startswith(';;', self.i):
                term = ';;'
                self.i += 2
            elif self.s.startswith(';&', self.i):
                self.err(';& and ;;& are outside the supported subset')
            arms.append((pats, body, term))
        return self.finish_compound(Node('case', start, self.i, word=word, arms=arms))

    def parse_pattern(self):
        s, start = self.s, self.i
        while self.i < self.n:
            c = s[self.i]
            if c in '|)' or c in '\n':
                break
            if c == '\\':
                self.i += 2
            elif c == "'":
                self.i = s.index("'", self.i + 1) + 1
            elif c == '"':
                self.i += 1
                while s[self.i] != '"':
                    self.i += 2 if s[self.i] == '\\' else 1
                self.i += 1
            elif c == '[':
                j = s.find(']', self.i + 2)
                if j < 0:
                    self.err('bad bracket in case pattern')
                self.i = j + 1
            elif c in ' \t':
                break
            else:
                self.i += 1
        return s[start:self.i]

    def parse_simple(self):
        start = self.i
        assigns, words, redirs = [], [], []
        s = self.s
        while True:
            self.skip_blank()
            if self.i >= self.n:
                break
            c = s[self.i]
            if c in ';&|)\n' or c == '#':
                break
            if c == '}' and not words and not assigns:
                break
            if REDIR_RE.match(s, self.i) and not s.startswith('<(', self.i) and not s.startswith('>(', self.i):
                redirs.append(self.parse_redir())
                continue
            if not words:
                m = ASSIGN_RE.match(s, self.i)
                if m:
                    astart = self.i
                    self.i = m.end()
                    val = self.parse_word(empty_ok=True)
                    assigns.append(Node('assign', astart, self.i, name=m.group(0).rstrip('=').rstrip('+'), value=val))
                    continue
            if s.startswith('<(', self.i) or s.startswith('>(', self.i):
                words.append(self.parse_procsub_word())
                continue
            if not words and s.startswith('[[', self.i) and (self.i + 2 < self.n and s[self.i + 2] in ' \t'):
                words.append(self.parse_dbrack())
                continue
            words.append(self.parse_word())
        if not (assigns or words or redirs):
            self.err('a command was expected')
        return Node('simple', start, self.i, assigns=assigns, words=words, redirs=redirs)

    def parse_dbrack(self):
        start = self.i
        self.i += 2
        nested = []
        s = self.s
        while True:
            if self.i >= self.n:
                self.err('[[ is not closed')
            c = s[self.i]
            if c in ' \t\n' and s.startswith(']]', self.i + 1) and (self.i + 3 >= self.n or s[self.i + 3] in DELIM):
                self.i += 3
                break
            if c == '\\':
                self.i += 2
            elif c == "'":
                self.i = s.index("'", self.i + 1) + 1
            elif c == '"':
                nested.append(self.parse_dq())
            elif c == '$':
                part = self.parse_dollar()
                if isinstance(part, Node):
                    nested.append(part)
            else:
                self.i += 1
        raw = s[start:self.i]
        return Node('word', start, self.i, parts=[('lit', raw)] + nested, dbrack=True, raw=raw)

    def parse_redir(self):
        start = self.i
        m = REDIR_RE.match(self.s, self.i)
        fd, op = m.group(1), m.group(2)
        self.i = m.end()
        self.skip_blank()
        if op in ('<<', '<<-'):
            ds = self.i
            w = self.parse_word()
            raw = self.s[ds:self.i]
            quoted = any(ch in raw for ch in '\'"\\')
            delim = re.sub(r'''['"\\]''', '', raw)
            node = Node('redir', start, self.i, op=op, fd=fd, target=None, heredoc=True)
            self.pending.append((delim, quoted, op == '<<-', node))
            return node
        if self.s.startswith('<(', self.i) or self.s.startswith('>(', self.i):
            target = self.parse_procsub_word()
        else:
            target = self.parse_word()
        return Node('redir', start, self.i, op=op, fd=fd, target=target, heredoc=False)

    # --- words and expansions ---
    def parse_procsub_word(self):
        start = self.i
        d = self.s[self.i]
        self.i += 2
        body = self.parse_list({')'})
        self.expect(')')
        ps = Node('ps', start, self.i, dir=d, body=body)
        return Node('word', start, self.i, parts=[ps])

    def parse_word(self, empty_ok=False):
        s, n = self.s, self.n
        start = self.i
        parts = []
        lit = []

        def flush():
            if lit:
                parts.append(('lit', ''.join(lit)))
                del lit[:]
        while self.i < n:
            c = s[self.i]
            if c in DELIM:
                break
            if c == '\\':
                if self.i + 1 < n and s[self.i + 1] == '\n':
                    self.i += 2
                    continue
                lit.append(s[self.i:self.i + 2])
                self.i += 2
            elif c == "'":
                flush()
                j = s.find("'", self.i + 1)
                if j < 0:
                    self.err('unterminated single quote')
                parts.append(('sq', s[self.i + 1:j]))
                self.i = j + 1
            elif c == '"':
                flush()
                parts.append(self.parse_dq())
            elif c == '$':
                flush()
                parts.append(self.parse_dollar())
            elif c == '`':
                flush()
                j = self.i + 1
                while j < n and s[j] != '`':
                    j += 2 if s[j] == '\\' else 1
                parts.append(Node('bt', self.i, j + 1, raw=s[self.i:j + 1]))
                self.i = j + 1
            else:
                lit.append(c)
                self.i += 1
        flush()
        if not parts and not empty_ok:
            self.err('a word was expected')
        return Node('word', start, self.i, parts=parts)

    def parse_dq(self):
        start = self.i
        self.i += 1
        parts = self.parse_dq_text(closing=True)
        return Node('dq', start, self.i, parts=parts)

    def parse_dq_text(self, closing=False):
        s, n = self.s, self.n
        parts, lit = [], []

        def flush():
            if lit:
                parts.append(('lit', ''.join(lit)))
                del lit[:]
        while True:
            if self.i >= n:
                if closing:
                    self.err('unterminated double quote')
                break
            c = s[self.i]
            if closing and c == '"':
                self.i += 1
                break
            if c == '\\' and self.i + 1 < n:
                lit.append(s[self.i:self.i + 2])
                self.i += 2
            elif c == '$':
                flush()
                parts.append(self.parse_dollar())
            elif c == '`':
                flush()
                j = self.i + 1
                while j < n and s[j] != '`':
                    j += 2 if s[j] == '\\' else 1
                parts.append(Node('bt', self.i, j + 1, raw=s[self.i:j + 1]))
                self.i = j + 1
            else:
                lit.append(c)
                self.i += 1
        flush()
        return parts

    def parse_dollar(self):
        s, n = self.s, self.n
        start = self.i
        nxt = s[self.i + 1] if self.i + 1 < n else ''
        if nxt == '(':
            if s.startswith('$((', self.i):
                return self.parse_arith()
            self.i += 2
            body = self.parse_list({')'})
            self.expect(')')
            return Node('cs', start, self.i, body=body)
        if nxt == '{':
            return self.parse_param()
        if nxt == "'":
            j = self.i + 2
            while j < n and s[j] != "'":
                j += 2 if s[j] == '\\' else 1
            self.i = j + 1
            return ('lit', s[start:self.i])
        if nxt == '"':
            self.i += 1
            return self.parse_dq()
        m = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!\-])').match(s, self.i)
        if m:
            self.i = m.end()
            return ('var', m.group(1))
        self.i += 1
        return ('lit', '$')

    def parse_arith(self):
        s, n = self.s, self.n
        start = self.i
        self.i += 3
        nested = []
        depth = 0
        while True:
            if self.i >= n:
                self.err('unterminated $(( ))')
            c = s[self.i]
            if c == '$' and s.startswith('$((', self.i):
                nested.append(self.parse_arith())
            elif c == '$' and s.startswith('$(', self.i):
                nested.append(self.parse_dollar())
            elif c == '(':
                depth += 1
                self.i += 1
            elif c == ')':
                if depth > 0:
                    depth -= 1
                    self.i += 1
                elif s.startswith('))', self.i):
                    self.i += 2
                    break
                else:
                    self.err('bad $(( ))')
            elif c == '"':
                nested.append(self.parse_dq())
            else:
                self.i += 1
        return Node('arith', start, self.i, nested=nested)

    def parse_param(self):
        s, n = self.s, self.n
        start = self.i
        self.i += 2
        nested = []
        depth = 1
        while depth:
            if self.i >= n:
                self.err('unterminated ${ }')
            c = s[self.i]
            if c == '\\':
                self.i += 2
            elif c == "'":
                self.i = s.index("'", self.i + 1) + 1
            elif c == '"':
                nested.append(self.parse_dq())
            elif c == '$' and s.startswith('${', self.i):
                nested.append(self.parse_param())
            elif c == '$' and s.startswith("$'", self.i):
                self.parse_dollar()
            elif c == '$' and s.startswith('$(', self.i):
                nested.append(self.parse_dollar())
            elif c == '}':
                depth -= 1
                self.i += 1
            else:
                self.i += 1
        return Node('param', start, self.i, nested=nested, raw=s[start:self.i])

    def parse_script(self):
        body = self.parse_list(set())
        self.skip_ws()
        if self.i < self.n:
            self.err('unparsed text %r' % self.s[self.i:self.i + 20])
        return Node('script', 0, self.n, body=body)


def shift(node, delta):
    node.start += delta
    if node.end is not None:
        node.end += delta
    for c in node.kids():
        shift(c, delta)


def link(node):
    for c in node.kids():
        c.parent = node
        link(c)


def walk(node):
    yield node
    for c in node.kids():
        for x in walk(c):
            yield x


# ----------------------------------------------------------------------------------------------------------------------
# The analyzer
# ----------------------------------------------------------------------------------------------------------------------

READERS = set('cat grep egrep fgrep awk gawk mawk sed head tail wc cut tr sort uniq stat date ps kill ls find mktemp cksum '
              'dirname basename cd pwd python python3 perl od readlink realpath id uname hostname'.split())
TRISTATE = set('grep egrep fgrep'.split())          # status 1 = "no match" is a result, not a failure
FORBIDDEN = set('eval xargs command builtin source . bash sh zsh env nohup'.split())
DECLS = set('local export readonly declare typeset'.split())
FILE_TEST_OPS = set('-e -f -d -L -h -r -w -x -s -S -p -b -c -O -G -k -u -g -nt -ot -ef'.split())
SAFE_CLEANUP = set('echo printf wr_drop wr_unlock rm : true exec'.split())
# The refusal ALLOWLIST (six rules). A refusal is exactly: `exit N` / `return N` (literal 1-255, no redirection, no `&`), or a
# call of a prelude helper, reached from the read only through `||`, `if !` / then and `{ }` groups that carry no redirection.
# Statements in front of the terminal must be inert. Anything else is not a refusal (UNLISTED), never a tool error.
INERT = set('echo printf : true rm wr_drop wr_unlock'.split())      # may stand in front of the terminal; the two helpers must not exit
# words a refusal relies on: a script that redefines, removes, disables or aliases one of them hides the refusal, so the
# files that source each other stop counting any refusal (the verdict is UNLISTED, not a tool error)
REFUSAL_WORDS = set('exit return break continue exec trap set shopt unset command builtin eval source . : true false'.split())
BUILTINS = set(('alias bg bind builtin caller cd command compgen complete compopt continue declare dirs disown echo enable eval '
                'exec exit export false fc fg getopts hash help history jobs kill let local logout mapfile popd printf pushd pwd '
                'read readarray readonly return set shift shopt source suspend test times trap true type typeset ulimit umask '
                'unalias unset wait [ . :').split())
TAINT_NAMES = REFUSAL_WORDS | BUILTINS | set(['rm'])           # a function named like one of these replaces it
SHADOW_CMDS = set('alias unalias enable'.split())
TRAP_SPECIAL = ('EXIT', '0', 'ERR', 'DEBUG', 'RETURN')
TRAP_SIGNALS = set('HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM STKFLT CHLD CONT STOP TSTP TTIN TTOU URG '
                   'XCPU XFSZ VTALRM PROF WINCH IO PWR SYS EMT INFO'.split())
TRAP_SAFE = set('wr_drop wr_unlock rm echo printf : true'.split())
REASONS = {
    'D': 'display-only value (a time or a quoted path in a message)',
    'K': 'the literal tab',
    'H': 'help text read from the script itself',
    'M': 'stdin drain',
    'X': 'terminal error formatter',
    'P': 'metadata test with a fail-closed recheck',
    'V': 'view-only read at the end of the script',
    'C': 'skip with continue, bound to its loop',
    'O': 'opaque program with pinned text',
}


class Occ:
    def __init__(self, file, kind, node, text):
        self.file, self.kind, self.node, self.text = file, kind, node, text
        self.status = None      # 'OK' | 'BAD'
        self.label = ''
        self.why = ''
        self.needs = set()
        self.func = None
        self.listed = None
        self.stmt = None
        self.idx = 0
        self.line = 0
        self.key = None


def word_lit(w):
    """The text of a word that is only literals/quotes, else None."""
    if w is None or w.k != 'word':
        return None
    out = []
    for p in w.parts:
        if isinstance(p, tuple) and p[0] in ('lit', 'sq'):
            out.append(p[1])
        elif isinstance(p, Node) and p.k == 'dq' and all(isinstance(q, tuple) and q[0] == 'lit' for q in p.parts):
            out.append(''.join(q[1] for q in p.parts))
        else:
            return None
    return ''.join(out)


def unesc(t):
    return re.sub(r'\\(.)', r'\1', t)


def cmd_name(simple):
    if simple.k != 'simple' or not simple.words:
        return None
    t = word_lit(simple.words[0])
    return unesc(t) if t is not None else '$'


def unwrapped(simple):
    """(name, args) of a simple command with any `command`/`builtin` wrappers and their options peeled off. A computed word
    after a wrapper (or as the command) has the name '$'."""
    words = list(simple.words)
    while words:
        t = word_lit(words[0])
        name = unesc(t) if t is not None else '$'
        if name in ('command', 'builtin'):
            words = words[1:]
            while words and (word_lit(words[0]) or '').startswith('-') and word_lit(words[0]) != '-':
                words = words[1:]
            continue
        return name, [word_lit(w) for w in words[1:]]
    return 'command', []


def normalize(text):
    out, i, n = [], 0, len(text)
    q = None
    while i < n:
        c = text[i]
        if q:
            out.append(c)
            if c == '\\' and q == '"' and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == q:
                q = None
        elif c in '\'"':
            q = c
            out.append(c)
        elif c == '\\' and i + 1 < n and text[i + 1] == '\n':
            i += 1
        elif c in ' \t\n':
            if out and out[-1] != ' ':
                out.append(' ')
        else:
            out.append(c)
        i += 1
    return ''.join(out).strip()


def digest(text):
    """sha256 of the normalized text, first 12 hex digits written as 4-4-4 (a plain 12-digit run trips the leak check)."""
    h = hashlib.sha256(normalize(text).encode('utf-8')).hexdigest()
    return '%s-%s-%s' % (h[:4], h[4:8], h[8:12])


class Analyzer:
    def __init__(self):
        self.files = {}         # name -> (src, parser, root)
        self.funcs = {}         # name -> [(file, node)]
        self.propagating = set()
        self.occs = []
        self.taint = {}         # file -> why it hides a refusal word (every file of a source component)
        self.helpers = {}       # file -> {prelude helper name}
        self.edges = {}
        self._loose = None
        self.envelope_on = False    # the file envelope is checked for a whole tree (fixtures opt in with a header)
        self.env = []               # (file, line, rule, why)
        self.env_files = set()
        self.env_why = {}
        self.out_files = []         # (path, why): files under bin/ or hooks/ that the gate does not read

    # --- loading ---
    def add(self, name, src):
        p = Parser(src)
        root = p.parse_script()
        link(root)
        self.files[name] = (src, p, root)
        for nd in walk(root):
            if nd.k == 'func':
                self.funcs.setdefault(nd.name, []).append((name, nd))

    def text(self, fname, node):
        return self.files[fname][0][node.start:node.end]

    def fname_of(self, node):
        while node.parent is not None:
            node = node.parent
        for name, (_, _, root) in self.files.items():
            if root is node:
                return name

    # --- words a refusal depends on must mean what they say ---
    # A file that redefines, removes, disables or aliases one of them is TAINTED: none of the files that source each other
    # with it count a refusal. This is a verdict (UNLISTED), not a tool error.
    def validate(self):
        self.taint = {}
        edges = {}
        for fname, (src, parser, root) in self.files.items():
            edges.setdefault(fname, set())
            for nd in walk(root):
                where = '%s line %d' % (fname, parser.line(nd.start))
                why = None
                if nd.k == 'func' and nd.name in TAINT_NAMES:
                    why = '%s: a function named %s shadows the shell word a refusal relies on' % (where, nd.name)
                elif nd.k == 'simple' and nd.words:
                    name, args = unwrapped(nd)
                    if name == '$' and cmd_name(nd) in ('command', 'builtin'):
                        why = '%s: a computed word after command/builtin can be eval, trap or unset' % where
                    elif name in SHADOW_CMDS:
                        why = '%s: %s can change what exit, return or a helper means' % (where, name)
                    elif name == 'eval':
                        why = '%s: eval can define or remove any of them' % where
                    elif name == 'unset':
                        if any(a is None for a in args) or '-f' in args or any(a in self.funcs or a in REFUSAL_WORDS for a in args if a):
                            why = '%s: unset names a function or a refusal word' % where
                    elif name == 'trap':
                        why = self.check_trap(where, args)
                    elif name in ('.', 'source'):
                        tgt = self.resolve_source(fname, nd)
                        if tgt is None:
                            why = '%s: a sourced file the gate cannot resolve to one of the scanned files' % where
                        elif tgt != fname:
                            edges[fname].add(tgt)
                            edges.setdefault(tgt, set()).add(fname)
                if why and fname not in self.taint:
                    self.taint[fname] = why
        # the files that source each other run in one shell: one hidden word taints them all
        seen = set()
        for f in list(edges):
            if f in seen:
                continue
            comp, todo = set(), [f]
            while todo:
                x = todo.pop()
                if x in comp:
                    continue
                comp.add(x)
                todo.extend(edges.get(x, ()))
            seen |= comp
            bad = [self.taint[x] for x in sorted(comp) if x in self.taint]
            if bad:
                for x in comp:
                    self.taint[x] = bad[0]
        self.edges = edges

    # the only spellings of "the folder this script lives in" the gate resolves; the value is how many folders up the result is
    # ---- the file envelope (closed allowlist at file level) ----
    # Before any statement is judged, every file must be written in the forms the tree uses today. A file outside the envelope
    # has no statement that is ever accepted or listed. The forms are matched literally on purpose: a rule per construct would
    # be a recognizer, and a recognizer can be out-thought; a list of what the files do can only be too short, which fails.
    # An entry script finds its own folder with a plain parameter expansion (no dirname, whose status would be lost) and one
    # checked capture: the case line, then HERE, the line after it. A library finds the repository root the same way.
    CANON_HERE_CASE = 'case $0 in */*) _d=${0%/*} ;; *) _d=. ;; esac'
    CANON_HERE = '$(cd -P "$_d" && pwd)'
    CANON_WR_ROOT = '$(cd -P "${BASH_SOURCE[0]%/*}/.." && pwd)'
    ENV_RUNNERS = {('bin/_common.sh', 'wr_run')}        # file + function that may run a computed command word, as exactly "$@"
    RE_SRC_ENTRY_BIN = re.compile(r'^"\$HERE/(_[A-Za-z0-9_]+)\.sh"$')
    RE_SRC_ENTRY_HOOK = re.compile(r'^"\$HERE/\.\./bin/(_[A-Za-z0-9_]+)\.sh"$')
    RE_RUN_SIBLING = re.compile(r'^"\$HERE/([A-Za-z0-9_-]+\.sh)"$')
    RE_RUN_TARGET = re.compile(r'^"\$HERE/((?:\.\./bin/)?[A-Za-z0-9][A-Za-z0-9_-]*\.sh)"$')
    RE_SRC_LIB = re.compile(r'^"\$WR_ROOT/bin/(_[A-Za-z0-9_]+)\.sh"$')

    def self_refs(self, f):
        """Words of file f that name the file itself ($0, ${0..}, BASH_SOURCE), apart from words that are only single-quoted text."""
        src, _, root = self.files[f]
        out = []
        for nd in walk(root):
            if nd.k == 'word' and nd.parts and not all(isinstance(q, tuple) and q[0] == 'sq' for q in nd.parts):
                if re.search(r'\$0\b|\$\{0|BASH_SOURCE', src[nd.start:nd.end]):
                    out.append(nd)
        return out

    def envelope(self):
        self.env = []
        wr_root_total = sum(self.writes_var(root, 'WR_ROOT') for (_, _, root) in self.files.values())

        def bad(f, nd, rule, why):
            line = self.files[f][1].line(nd.start) if nd is not None else 0
            self.env.append((f, line, rule, why))
        for f in sorted(self.files):
            src, parser, root = self.files[f]
            folder, base = posixpath.dirname(f), posixpath.basename(f)
            lib = base.startswith('_')
            if lib and folder != 'bin':
                bad(f, None, 'E1', 'a library (_*.sh) lives in bin/ only')
            # E2 sourcing and the folder variables
            here_hits = [a for d in walk(root) if d.k == 'simple' for a in d.assigns if a.name == 'HERE']
            if lib:
                if self.writes_var(root, 'HERE'):
                    bad(f, None, 'E2', 'a sourced file never sets HERE')
                canon = [a for d in walk(root) if d.k == 'simple' for a in d.assigns if a.name == 'WR_ROOT']
                for w in self.self_refs(f):
                    inside = any(a.value.start <= w.start and w.end <= a.value.end and src[a.value.start:a.value.end].strip() == self.CANON_WR_ROOT
                                 for a in canon)
                    if not inside:
                        bad(f, w, 'E2', 'a sourced file never names itself ($0, BASH_SOURCE) except in the one canonical WR_ROOT line')
            else:
                if self.writes_var(root, 'WR_ROOT'):
                    bad(f, None, 'E2', 'only the library sets WR_ROOT')
                here_nodes = [d for d in walk(root) if d.k == 'simple' and any(a.name == 'HERE' for a in d.assigns)]

                def bare(it):
                    while True:
                        if it.k == 'andor' and (len(it.parts) == 1 or it.ops == ['||']):
                            it = it.parts[0]
                        elif it.k == 'pipe' and len(it.cmds) == 1 and not it.neg:
                            it = it.cmds[0]
                        else:
                            return it
                top = [it for it in root.body.items if any(bare(it) is d for d in here_nodes)]    # the statement itself, not a group around it
                items = root.body.items
                at = items.index(top[0]) if top else -1
                ok_here = (len(here_hits) == 1 and self.writes_var(root, 'HERE') == 1
                           and src[here_hits[0].value.start:here_hits[0].value.end].strip() == self.CANON_HERE
                           and at > 0
                           and src[items[at - 1].start:items[at - 1].end].strip() == self.CANON_HERE_CASE
                           and self.writes_var(root, '_d') == 2)
                if not ok_here:
                    bad(f, None, 'E2', 'an entry script sets HERE exactly once, at top level, by the canonical case line and the canonical line after it')
            if lib and f == 'bin/_common.sh' or (lib and wr_root_total):
                pass
            for nd in walk(root):
                if nd.k != 'simple' or not nd.words:
                    continue
                name, args = unwrapped(nd)
                text0 = src[nd.words[1].start:nd.words[1].end] if len(nd.words) > 1 else ''
                if name == 'source':
                    bad(f, nd, 'E2', 'only the dot form sources a file')
                elif name == '.':
                    m = None
                    if len(nd.words) == 2:
                        if lib:
                            m = self.RE_SRC_LIB.match(text0)
                        elif folder == 'hooks':
                            m = self.RE_SRC_ENTRY_HOOK.match(text0)
                        else:
                            m = self.RE_SRC_ENTRY_BIN.match(text0)
                    if m is None:
                        bad(f, nd, 'E2', 'a sourced path has one of three exact forms ($HERE/_x.sh, $HERE/../bin/_x.sh, $WR_ROOT/bin/_x.sh)')
                    elif 'bin/%s.sh' % m.group(1) not in self.files:
                        bad(f, nd, 'E2', 'a sourced library is not one of the scanned files')
                # E3 exec
                elif name == 'exec':
                    if len(nd.words) != 1:
                        bad(f, nd, 'E3', 'exec only changes descriptors; it never runs a command')
                    for r in nd.redirs:
                        t = word_lit(r.target) if r.target is not None else None
                        fd_ok = r.fd.isdigit() and int(r.fd) >= 3
                        dup_ok = r.op not in ('>&', '<&') or (t == '-' or (t is not None and t.isdigit() and int(t) >= 3))
                        if not (fd_ok and dup_ok):
                            bad(f, nd, 'E3', 'exec redirects only descriptors 3 and up, and never duplicates onto 1 or 2')
                # E4 words that can run anything
                elif name == 'eval':
                    bad(f, nd, 'E4', 'eval is outside the envelope')
                elif name in ('command', 'builtin') or cmd_name(nd) in ('command', 'builtin'):
                    if not (cmd_name(nd) == 'command' and [word_lit(w) for w in nd.words[1:2]] == ['-v']):
                        bad(f, nd, 'E4', 'command and builtin wrappers are outside the envelope (command -v is the one lookup form)')
                elif name == 'trap':
                    if not args or any(a is None for a in args):
                        bad(f, nd, 'E4', 'a trap has a literal action and literal signal names')
                elif cmd_name(nd) == '$':
                    fn = nd
                    while fn is not None and fn.k != 'func':
                        fn = fn.parent
                    w0 = src[nd.words[0].start:nd.words[0].end]
                    sib = self.RE_RUN_SIBLING.match(w0)
                    if sib and not lib and posixpath.join(folder, sib.group(1)) in self.files:
                        continue        # an entry script runs a named sibling: "$HERE/x.sh" (HERE is the canonical line, checked above)
                    if not (w0 == '"$@"' and fn is not None and (f, fn.name) in self.ENV_RUNNERS):
                        bad(f, nd, 'E4', 'a computed command word is outside the envelope (one "$@" runner is listed by file and function)')
        # a literal trap action is code that runs wherever its signal, DEBUG or EXIT lands, so the text inside it is held to the
        # same exec and word rules as the statements around it (an exec in an action changes the descriptors of whatever runs next)
        for f in sorted(self.files):
            root = self.files[f][2]
            for d in walk(root):
                if d.k != 'simple' or not d.words or unwrapped(d)[0] != 'trap':
                    continue
                args = unwrapped(d)[1]
                if args and args[0] == '--':
                    args = args[1:]
                if len(args) < 2 or args[0] is None or args[0] in ('-', '-p', '-l'):
                    continue
                try:
                    tree = Parser(args[0]).parse_script()
                except ParseError:
                    bad(f, d, 'E4', 'a trap action must parse as a script')
                    continue
                link(tree)
                for nd in walk(tree):
                    if nd.k != 'simple' or not nd.words:
                        continue
                    if unwrapped(nd)[0] in ('exec', 'eval', 'source', '.', 'command', 'builtin', 'trap', '$') or cmd_name(nd) in ('command', 'builtin'):
                        bad(f, d, 'E4', 'a trap action holds only plain calls (no exec, eval, source, wrapper, nested trap or computed word)')
        for path, why in self.out_files:
            self.env.append((path, 0, 'E1', why))
        # a file outside the envelope runs in the same shell as everything it sources and everything that sources it: it can
        # redirect descriptors, define words or rewrite variables for all of them, so no row in that whole closure is trusted
        self.env_files, self.env_why = set(), {}
        for f, _, _, why in self.env:
            for g in ((self.same_shell(f) | {f}) if f in self.files else {f}):
                self.env_files.add(g)
                self.env_why.setdefault(g, why if g == f else '%s shares a shell with it: %s' % (f, why))

    DIR_FORMS = {
        '$(dirname "$0")': 0,
        '"$(dirname "$0")"': 0,
        '"$(cd "$(dirname "$0")" && pwd)"': 0,
        '"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"': 0,
        '"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"': 1,
        '"$(cd "$(dirname "$0")/.." && pwd)"': 1,
        '$(cd -P "$_d" && pwd)': 0,
        '$(cd -P "${BASH_SOURCE[0]%/*}/.." && pwd)': 1,
    }

    @staticmethod
    def src_tail(nd):
        """The last path component a `.` names, or None when the word does not end in a literal file name."""
        if len(nd.words) < 2:
            return None
        parts = nd.words[1].parts
        if len(parts) == 1 and isinstance(parts[0], Node) and parts[0].k == 'dq':
            parts = parts[0].parts
        if not parts or not (isinstance(parts[-1], tuple) and parts[-1][0] == 'lit'):
            return None
        t = parts[-1][1].rsplit('/', 1)[-1]
        return t or None

    def loose_edges(self):
        """Who may source whom, over-estimated by file NAME only (a `.` whose target cannot be told may source anything). It is used
        to refuse, never to credit: the true edges need the very resolution this feeds."""
        if self._loose is None:
            names = {}
            for f in self.files:
                names.setdefault(posixpath.basename(f), set()).add(f)
            down = {f: set() for f in self.files}
            tails, unknown = {}, False
            for f, (_, _, root) in self.files.items():
                for nd in walk(root):
                    if nd.k == 'simple' and nd.words and unwrapped(nd)[0] in ('.', 'source'):
                        t = self.src_tail(nd)
                        if t is None:
                            unknown = True
                            down[f] |= set(self.files)
                        else:
                            tails.setdefault(t, set()).add(f)
                            down[f] |= names.get(t, set())
            up = {}
            for a, bs in down.items():
                for b in bs:
                    up.setdefault(b, set()).add(a)
            self._loose = (down, up, tails, unknown)
        return self._loose

    def same_shell(self, f):
        """Every file whose code can run in the same shell as f's: what f sources, what sources f, and what those source."""
        down, up, _, _ = self.loose_edges()

        def closure(starts, g):
            out, todo = set(), list(starts)
            while todo:
                x = todo.pop()
                if x not in out:
                    out.add(x)
                    todo.extend(g.get(x, ()))
            return out
        anc = closure([f], up)
        return closure([f], down) | anc | closure(anc, down)

    def writes_var(self, root, var):
        """How many places in this tree write the variable (assignment, `read VAR`, `export VAR=..`, a `for` variable...)."""
        n = 0
        for d in walk(root):
            if d.k == 'simple':
                n += sum(1 for a in d.assigns if a.name == var)
                if d.words and any(w_ is not None and (w_ == var or w_.startswith(var + '=') or w_.endswith(' ' + var))
                                   for w_ in (word_lit(w) for w in d.words[1:])):
                    n += 1
            if d.k == 'for' and getattr(d, 'var', None) == var:
                n += 1
        return n

    def resolve_source(self, fname, nd):
        """The scanned file that a `. "$VAR/rel/path"` brings in, or None. VAR must be assigned exactly once in this file, by a
        top-level statement before the `.`, in one of DIR_FORMS, and never touched by another command; the path is then worked
        out from this file's own folder. Anything else (a basename match, another folder, a file the gate does not scan) is None."""
        if len(nd.words) != 2:
            return None
        parts = nd.words[1].parts
        if len(parts) == 1 and isinstance(parts[0], Node) and parts[0].k == 'dq':
            parts = parts[0].parts
        if len(parts) < 2 or not (isinstance(parts[0], tuple) and parts[0][0] == 'var'):
            return None
        if not all(isinstance(q, tuple) and q[0] == 'lit' for q in parts[1:]):
            return None
        var = parts[0][1]
        rel = ''.join(q[1] for q in parts[1:])
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', var) or not rel.startswith('/') or '$' in rel:
            return None
        src, _, root = self.files[fname]
        hits = [a for d in walk(root) if d.k == 'simple' for a in d.assigns if a.name == var]
        if len(hits) != 1 or hits[0].parent is None or hits[0].parent.k != 'simple' or hits[0].parent.words:
            return None
        key = src[hits[0].value.start:hits[0].value.end].strip()
        up = self.DIR_FORMS.get(key)
        if up is None:
            return None
        _, _, tails, unknown = self.loose_edges()
        if ('"$0"' in key or '"$_d"' in key) and (unknown or any(g != fname for g in tails.get(posixpath.basename(fname), ()))):
            return None         # $0 is the file that was run: when this file is sourced it names the sourcer, not this file
        # a top-level statement, before the `.` and not inside anything
        top = None
        for n, it in enumerate(root.body.items):
            if any(x is hits[0] for x in walk(it)):
                top = n
        dot = nd
        while dot.parent is not None and dot.parent is not root.body:
            dot = dot.parent
        if top is None or dot.parent is None or root.body.items.index(dot) <= top:
            return None
        if not (root.body.items[top].k == 'andor' and len(root.body.items[top].parts) <= 2):
            return None
        # nothing else may write the variable, in this file or in any file that runs in the same shell
        for g in self.same_shell(fname) | {fname}:
            if self.writes_var(self.files[g][2], var) != (1 if g == fname else 0):
                return None
        here = posixpath.dirname(fname)
        for _ in range(up):
            here = posixpath.dirname(here)
        path = posixpath.normpath(posixpath.join(here, rel.lstrip('/')))
        return path if path in self.files else None

    def check_trap(self, where, args):
        """The reason a trap action can end the shell or rewrite the exit status, or None. Any signal counts: a signal can be sent
        from inside a substitution, and a closed pipe raises PIPE."""
        if any(a is None for a in args):
            return '%s: trap with a computed argument' % where
        if not args or args[0] in ('-p', '-l'):
            return None
        if args[0] == '--':
            args = args[1:]
            if not args:
                return None
        action, sigs = args[0], args[1:]
        for x in sigs:
            if x not in TRAP_SPECIAL and not re.fullmatch(r'[0-9]{1,2}', x) and re.sub(r'^SIG', '', x) not in TRAP_SIGNALS:
                return '%s: trap on %s, which is not a signal name this gate knows' % (where, x)
        if not sigs or action in ('', '-'):
            return None
        try:
            tree = Parser(action).parse_script()
        except ParseError as e:
            return '%s: trap action does not parse (%s)' % (where, e)
        link(tree)
        for c in walk(tree):
            if c.k in ('cs', 'ps', 'bt', 'func'):
                return '%s: trap action holds a substitution or a function' % where
            if c.k == 'simple' and c.words:
                nm = cmd_name(c)
                if nm not in TRAP_SAFE:
                    return '%s: a trap action may end the shell or rewrite the exit status; only %s are allowed in it, not %s' % (
                        where, ' '.join(sorted(TRAP_SAFE)), nm)
                if self.can_exit(nm, set()):
                    return '%s: trap helper %s can end the shell' % (where, nm)
        return None

    def can_exit(self, name, seen):
        """True when function `name`, or a function it calls, runs `exit` or `kill` (a return only leaves the function)."""
        if name in seen:
            return False
        seen.add(name)
        for _, fn in self.funcs.get(name, []):
            for d in walk(fn):
                if d.k == 'simple' and d.words:
                    nm = cmd_name(d)
                    if nm == 'exec' and len(d.words) == 1 and all(
                            r.op in ('>&', '<&') and r.target is not None and word_lit(r.target) == '-'
                            and r.fd.isdigit() and int(r.fd) >= 3 for r in d.redirs):
                        continue       # `exec 8>&-` only closes a descriptor of 3 or up: it cannot fail and never leaves the shell
                    if nm in ('exit', 'kill', 'exec', 'command', 'builtin', 'eval', '$') or (nm in self.funcs and self.can_exit(nm, seen)):
                        return True
        return False

    def tainted(self, node):
        return self.taint.get(self.fname_of(node))

    def proc_ok(self, node):
        """Rule 5. True when the refusal at `node` is reached from the read only through `||`, `if !`/then and `{ }`: not in the
        background, not a pipeline stage, not a subshell, not inside a substitution, and no redirection on any enclosing node
        (a redirection that fails skips the whole command)."""
        n = node
        while n is not None:
            if getattr(n, 'bg', False):
                return False
            p = n.parent
            if p is None:
                return True
            if p.k == 'pipe' and len(p.cmds) > 1:
                return False
            if p.k in ('subshell', 'cs', 'ps', 'bt'):
                return False
            if p.k in ('group', 'if', 'while', 'for', 'case') and getattr(p, 'redirs', None):
                return False
            if p.k in ('func', 'script'):
                return True
            n = p
        return True

    # --- refusal: the six rules ---
    def why_not(self, node, default):
        """The reason text for a branch that is not a refusal: when the file hides a refusal word and the branch looks like a
        refusal, say that instead of the generic text."""
        t = self.tainted(node)
        if t and any(d.k == 'simple' and d.words and (cmd_name(d) in ('exit', 'return') or cmd_name(d) in self.funcs) for d in walk(node)):
            return 'this file hides or redefines a word the refusal relies on (%s)' % t
        return default

    def returned_from(self, node):
        """The name of the function whose status is the refusal when `node` ends in `return N` (its caller sees the status), else None."""
        if not any(d.k == 'simple' and d.words and cmd_name(d) == 'return' for d in walk(node)):
            return None
        for a in self.ancestors(node):
            if a.k == 'func':
                return a.name
        return None

    def exit_status(self, w):
        """The literal status 1-255 a word spells, else None (256 would wrap to 0)."""
        t = word_lit(w)
        if t is not None and re.fullmatch(r'[1-9][0-9]{0,2}', t) and int(t) <= 255:
            return int(t)
        return None

    def plain_word(self, w):
        """A word that is only literals, quotes and plain `$name` references: expanding it cannot fail or run anything."""
        for p in w.parts:
            if isinstance(p, Node) and p.k == 'dq':
                if not all(isinstance(q, tuple) and q[0] in ('lit', 'var') and not (q[0] == 'lit' and '$' in q[1]) for q in p.parts):
                    return False
            elif not (isinstance(p, tuple) and p[0] in ('lit', 'sq', 'var')):
                return False
            if isinstance(p, tuple) and p[0] == 'lit' and '$' in p[1]:
                return False        # `$[1/0]` and other `$` forms the parser keeps as text
        return True

    def in_function(self, node):
        return any(a.k == 'func' for a in self.ancestors(node))

    def terminal(self, sm, bare_ok):
        """Rules 1-3: a simple command, no assignment, no redirection at all, that exits/returns a literal status or calls a
        prelude helper."""
        if sm.assigns or sm.redirs or not sm.words:
            return False
        name = cmd_name(sm)
        args = sm.words[1:]
        if name in ('exit', 'return'):
            if name == 'return' and not self.in_function(sm):
                return False        # outside a function (or a sourced file) return fails and the script goes on
            if not args:
                return bare_ok
            return len(args) == 1 and self.exit_status(args[0]) is not None
        if name in self.helpers.get(self.fname_of(sm), ()):
            return all(self.plain_word(w) for w in args)
        return False

    def inert(self, item):
        """A statement in front of the terminal that cannot stop the list before it gets there."""
        if item.k != 'andor' or len(item.parts) != 1 or getattr(item, 'bg', False):
            return False
        pipe = item.parts[0]
        if pipe.k != 'pipe' or len(pipe.cmds) != 1 or pipe.neg or pipe.cmds[0].k != 'simple':
            return False
        sm = pipe.cmds[0]
        if sm.assigns or not sm.words:
            return False
        name = cmd_name(sm)
        if any(d.k in ('cs', 'ps', 'bt') for d in walk(sm)):
            return False        # a substitution can run anything, even a kill that fires a trap
        return name in INERT and not self.can_exit(name, set())

    def refusal_stmt(self, item, bare_ok=False):
        """item: an andor/pipe/group/simple. True when running it always ends the function or script with a nonzero status."""
        if self.tainted(item):
            return False
        return self._refusal(item, bare_ok)

    def _refusal(self, item, bare_ok):
        if item.k == 'andor':
            if len(item.parts) != 1 or getattr(item, 'bg', False):
                return False
            return self._refusal(item.parts[0], bare_ok)
        if item.k == 'pipe':
            if len(item.cmds) != 1 or item.neg:
                return False
            return self._refusal(item.cmds[0], bare_ok)
        if item.k == 'group':
            if getattr(item, 'redirs', None):
                return False
            return self._refusal_list(item.body, bare_ok)
        if item.k == 'simple':
            return self.terminal(item, bare_ok)
        return False

    def refusal_list(self, lst, bare_ok=False):
        if self.tainted(lst):
            return False
        return self._refusal_list(lst, bare_ok)

    def _refusal_list(self, lst, bare_ok):
        items = lst.items
        if not items or not all(self.inert(x) for x in items[:-1]):
            return False
        # a bare exit/return returns the status of the command before it: only a branch that is nothing else keeps the read's status
        return self._refusal(items[-1], bare_ok and len(items) == 1)

    # --- rule 4: prelude helpers ---
    def prelude(self, fname):
        """(the helper names this file defines in its prelude, the files its checked top-level `.` lines bring in). The prelude is
        the leading run of top-level statements that are a definition, an assignment of literals, `set -o pipefail`, `trap '' PIPE`,
        a checked `.`, or a checked `NAME=$(...)`; it ends at the first statement that is anything else."""
        defs, srcs = {}, []
        root = self.files[fname][2]
        for it in root.body.items:
            if getattr(it, 'bg', False) or it.k != 'andor':
                break
            first = it.parts[0]
            if first.k != 'pipe' or len(first.cmds) != 1 or first.neg:
                break
            c = first.cmds[0]
            if len(it.parts) == 1:
                if c.k == 'case' and self.files[fname][0][it.start:it.end].strip() == self.CANON_HERE_CASE:
                    continue        # the one line that finds the script's own folder (the checked capture after it is allowed below)
                if c.k == 'func':
                    if c.body.k != 'group' or getattr(c.body, 'redirs', None):
                        break       # a redirection on the definition: every call may be skipped
                    defs[c.name] = c
                    continue
                if c.k != 'simple' or c.redirs:
                    break
                if not c.words:
                    if all(word_lit(a.value) is not None for a in c.assigns):
                        continue
                    break
                name = cmd_name(c)
                args = [word_lit(w) for w in c.words[1:]]
                if name == 'set' and args == ['-o', 'pipefail']:
                    continue
                if name == 'trap' and args == ['', 'PIPE']:
                    continue
                break
            # a checked statement: `. file || exit N`, `NAME=$(...) || exit N`
            if len(it.parts) != 2 or it.ops != ['||'] or c.k != 'simple' or c.redirs:
                break
            rhs = it.parts[1]
            if not self.plain_exit(rhs):
                break
            if c.words and cmd_name(c) in ('.', 'source'):
                tgt = self.resolve_source(fname, c)
                if tgt is not None and tgt != fname:
                    srcs.append(tgt)
                continue
            if not c.words and len(c.assigns) == 1 and not self.calls_script_function(c):
                continue
            break
        return defs, srcs

    def plain_exit(self, pipe):
        """`exit N` alone, or in a { } with nothing but inert items in front of it (no helpers: this runs before any exist)."""
        if pipe.k != 'pipe' or len(pipe.cmds) != 1 or pipe.neg:
            return False
        c = pipe.cmds[0]
        if c.k == 'group':
            if getattr(c, 'redirs', None):
                return False
            items = c.body.items
            return bool(items) and all(self.inert(x) for x in items[:-1]) and self.is_exit_item(items[-1])
        return c.k == 'simple' and self.is_exit_cmd(c)

    def is_exit_item(self, it):
        if it.k != 'andor' or len(it.parts) != 1 or getattr(it, 'bg', False):
            return False
        return self.plain_exit(it.parts[0])

    def is_exit_cmd(self, c):
        return not c.assigns and not c.redirs and c.words and cmd_name(c) == 'exit' and len(c.words) == 2 \
            and self.exit_status(c.words[1]) is not None

    def calls_script_function(self, nd):
        return any(d.k == 'simple' and d.words and cmd_name(d) in self.funcs for d in walk(nd))

    def helper_body_ok(self, fn):
        """A rule-1 body: inert items, then a literal `exit N`."""
        body = fn.body
        items = body.body.items
        return bool(items) and all(self.inert(x) for x in items[:-1]) and self.is_exit_item(items[-1])

    def compute_helpers(self):
        self.helpers = {}
        pre = {f: self.prelude(f) for f in self.files}
        count = {}
        for name, defs in self.funcs.items():
            for f, _ in defs:
                count.setdefault(name, 0)
                count[name] += 1

        def visible(f, seen):
            if f in seen:
                return {}
            seen = seen | {f}
            out = dict(pre[f][0])
            for g in pre[f][1]:
                out.update(visible(g, seen))
            return out
        for f in self.files:
            names = set()
            if f not in self.taint:
                for name, fn in visible(f, set()).items():
                    # defined exactly once across the file and everything it sources, and a rule-1 body
                    comp_defs = sum(1 for g in self.component(f) for gn in [self.files[g][2]] for d in walk(gn)
                                    if d.k == 'func' and d.name == name)
                    if comp_defs == 1 and self.helper_body_ok(fn):
                        names.add(name)
            self.helpers[f] = names

    def component(self, f):
        comp, todo = set(), [f]
        while todo:
            x = todo.pop()
            if x in comp:
                continue
            comp.add(x)
            todo.extend(self.edges.get(x, ()))
        return comp

    def ancestors(self, node):
        p = node.parent
        while p is not None:
            yield p
            p = p.parent

    # --- pipefail ---
    def pipefail_active(self, pipe):
        n = pipe
        while n.parent is not None:
            p = n.parent
            if p.k == 'list':
                idx = p.items.index(n)
                state = False
                for it in p.items[:idx]:
                    eff = self.opt_effect(it)
                    if eff is not None:
                        state = (eff == 'on')
                if state:
                    return True
                o = p.parent
                if o is not None and o.k in ('cs', 'ps', 'subshell', 'func', 'script'):
                    return False
            n = p
        return False

    def opt_effect(self, item):
        """'on' for a top-level `set -o pipefail`; 'off' for anything that holds, or calls a function that holds, a `set`, `shopt`,
        `eval`, `.` or `source` that could switch pipefail off, even inside an if, a loop, a group or after `||`; else None."""
        if self.set_stmt(item):
            return 'on'
        for d in walk(item):
            if d.k == 'simple' and d.words:
                name, args = unwrapped(d)
                if name in ('set', 'shopt', 'eval', '.', 'source', '$') and not (name == 'set' and args == ['-o', 'pipefail']):
                    return 'off'
                if name in self.funcs and self.touches_options(name, set()):
                    return 'off'
        return None

    def touches_options(self, name, seen):
        if name in seen:
            return False
        seen.add(name)
        for _, fn in self.funcs.get(name, []):
            for d in walk(fn):
                if d.k == 'simple' and d.words:
                    nm, args = unwrapped(d)
                    if nm in ('set', 'shopt', 'eval', '.', 'source', '$') and not (nm == 'set' and args == ['-o', 'pipefail']):
                        return True
                    if nm in self.funcs and self.touches_options(nm, seen):
                        return True
        return False

    def set_stmt(self, item):
        """True for `set -o pipefail`, False for any other `set`/`shopt` that could change it, else None."""
        if item.k != 'andor' or len(item.parts) != 1:
            return None
        pipe = item.parts[0]
        if len(pipe.cmds) != 1 or pipe.cmds[0].k != 'simple':
            return None
        sm = pipe.cmds[0]
        name = cmd_name(sm)
        if name not in ('set', 'shopt'):
            return None
        args = [word_lit(w) for w in sm.words[1:]]
        return args == ['-o', 'pipefail']

    # --- status consumption: where does the failure of `n` go? ---
    def bad(self, why, needs=()):
        return ('BAD', why, set(needs), None)

    def ok(self, label, func=None):
        return ('OK', label, set(), func)

    def consume(self, n, st='F', stop=None):
        while True:
            p = n.parent
            if p is None:
                return self.bad('no enclosing statement')
            k = p.k
            if k == 'pipe':
                idx = p.cmds.index(n)
                if idx < len(p.cmds) - 1 and not self.pipefail_active(p):
                    return self.bad('a pipeline stage whose status is dropped (no set -o pipefail in this substitution or subshell)')
                if p.neg:
                    st = 'T' if st == 'F' else 'F'
                n = p
                continue
            if k == 'andor':
                i = p.parts.index(n)
                nxt = p.ops[i] if i < len(p.ops) else None
                if nxt == '||':
                    if st == 'F':
                        rhs = p.parts[i + 1]
                        if self.refusal_stmt(rhs, bare_ok=True):
                            if not self.proc_ok(p):
                                return self.bad('the refusal runs in another process (background job, pipeline stage, subshell)')
                            return self.ok('REFUSE', func=self.returned_from(rhs))
                        if self.is_continue(rhs):
                            return self.bad('the failure only continues the loop', needs=('C',))
                        return self.bad(self.why_not(rhs, 'the failure falls back to a default or is ignored (|| x=.., || true, || echo ..)'))
                    n = p
                    continue
                if nxt == '&&':
                    if st == 'F':
                        n = p
                        continue
                    return self.bad('a negated status is masked by the rest of the chain')
                n = p
                continue
            if k == 'list':
                i = p.items.index(n)
                if i < len(p.items) - 1:
                    if self.is_saved_status(p.items[i + 1]):
                        return self.saved(p, i, st)
                    return self.bad('the statement after it runs whatever the status was')
                o = p.parent
                if o is None:
                    return self.bad('detached list')
                if o.k == 'script':
                    return self.bad('last statement of the script: its status is the exit status', needs=('V',))
                if o.k in ('group', 'subshell'):
                    n = o
                    continue
                if o.k == 'func':
                    return self.ok('PROP', func=o.name)
                if o.k == 'if':
                    for j, (cond, body) in enumerate(o.clauses):
                        if p is cond:
                            if st == 'T':
                                if not self.refusal_list(body):
                                    return self.bad(self.why_not(body, 'the then branch does not refuse'))
                                if not self.proc_ok(p):
                                    return self.bad('the refusal runs in another process (background job, pipeline stage, subshell)')
                                return self.ok('REFUSE', func=self.returned_from(body))
                            if j < len(o.clauses) - 1:
                                return self.bad('an elif chain: the failure goes to the next condition')
                            if o.els is not None and self.refusal_list(o.els):
                                if not self.proc_ok(p):
                                    return self.bad('the refusal runs in another process (background job, pipeline stage, subshell)')
                                return self.ok('REFUSE', func=self.returned_from(o.els))
                            return self.bad(self.why_not(o.els, 'the failure falls through the if (no else that refuses)') if o.els is not None
                                            else 'the failure falls through the if (no else that refuses)')
                    n = o
                    continue
                if o.k == 'case':
                    n = o
                    continue
                if o.k in ('while', 'for'):
                    return self.bad('last status of a loop body or loop condition is not the status of the read')
                if o.k in ('cs', 'ps'):
                    if stop is o:
                        return self.ok('CSEND')
                    return self.cs_value(o, st)
                return self.bad('unsupported enclosing construct %s' % o.k)
            if k == 'case':
                return self.bad('read inside a case word')
            if k == 'func':
                return self.ok('PROP', func=p.name)
            if k in ('group', 'subshell', 'if', 'while', 'for'):
                return self.bad('redirect or word of a compound command')
            return self.bad('unsupported context %s' % k)

    def is_continue(self, x):
        while x.k in ('andor', 'pipe', 'group'):
            if x.k == 'andor':
                if len(x.parts) != 1:
                    return False
                x = x.parts[0]
            elif x.k == 'pipe':
                if len(x.cmds) != 1:
                    return False
                x = x.cmds[0]
            else:
                if len(x.body.items) != 1:
                    return False
                x = x.body.items[0]
        return x.k == 'simple' and cmd_name(x) == 'continue' and len(x.words) == 1

    def cs_value(self, cs, st):
        w = cs.parent
        while w is not None and w.k == 'dq':
            w = w.parent
        if cs.k == 'ps':
            return self.bad('a process substitution: its status is never seen')
        if w is None or w.k != 'word':
            return self.bad('substitution inside an expansion, not a whole assignment')
        sm = w.parent
        if sm is not None and sm.k == 'assign':
            sm = sm.parent
            if sm.k == 'simple' and not sm.words:
                count = sum(1 for a in sm.assigns for d in walk(a.value) if d.k in ('cs', 'ps') and self.nearest_sub(d) is None)
                if count != 1:
                    return self.bad('more than one substitution in one assignment: only the last status is kept')
                return self.consume(sm, st)
            if sm.k == 'simple' and sm.words:
                return self.bad('assignment in front of a command')
        if sm is not None and sm.k == 'simple' and sm.words:
            name = cmd_name(sm)
            if name in DECLS:
                return self.bad('a declaration builtin keeps its own status and hides the substitution status')
            return self.bad('substitution used as an argument: its status is lost')
        return self.bad('substitution in an unsupported position (%s)' % (sm.k if sm is not None else '?'))

    def nearest_sub(self, d):
        p = d.parent
        while p is not None:
            if p.k in ('cs', 'ps'):
                return p
            p = p.parent
        return None

    # --- saved status: x=$(cmd); rc=$? ... ---
    def is_saved_status(self, item):
        sm = self.single_simple(item)
        if sm is None or sm.words or len(sm.assigns) != 1:
            return False
        v = sm.assigns[0].value
        return v.k == 'word' and len(v.parts) == 1 and v.parts[0] == ('var', '?')

    def single_simple(self, item):
        if item.k == 'andor' and len(item.parts) == 1:
            item = item.parts[0]
        if item.k == 'pipe' and len(item.cmds) == 1 and not item.neg:
            item = item.cmds[0]
        return item if item.k == 'simple' else None

    def saved(self, lst, i, st):
        if st != 'F':
            return self.bad('negated status saved')
        var = self.single_simple(lst.items[i + 1]).assigns[0].name
        k = i + 2
        while k < len(lst.items) and self.v_literal_if(lst.items[k], var):
            k += 1
        if k >= len(lst.items):
            return self.bad('the saved status is never tested')
        it = self.unwrap(lst.items[k])
        if it is None:
            return self.bad('the saved status is not tested by an if or case')
        if it.k == 'if':
            cond = it.clauses[0][0]
            t = self.first_test(cond, var)
            if t is None:
                return self.bad('the statement after the saved status does not test it')
            op, lit = t
            if op in ('!=', '-ne') and lit == '0':
                if self.refusal_list(it.clauses[0][1]):
                    if getattr(it, 'redirs', None) or not self.proc_ok(lst):
                        return self.bad('the refusal runs in another process or under a redirection')
                    return self.ok('I3')
                return self.bad(self.why_not(it.clauses[0][1], 'the failed-status branch reports an error but does not return or exit'))
            if op in ('=', '-eq', '==') and lit == '0':
                body = it.clauses[0][1]
                if it.els is not None:
                    return self.bad('the success test has an else branch')
                if not self.ends_success(body):
                    return self.bad('the success branch can fall through into the failure path')
                if self.refuses_after(lst.items, k):
                    if not self.proc_ok(lst):
                        return self.bad('the refusal runs in another process or under a redirection')
                    return self.ok('I3')
                return self.bad('what follows the success branch does not end in a refusal')
            return self.bad('the saved status is compared with something other than 0')
        if it.k == 'case':
            return self.i5(it, var, lst, i)
        return self.bad('the saved status is not tested by an if or case')

    def unwrap(self, item):
        if item.k == 'andor' and len(item.parts) == 1:
            item = item.parts[0]
        if item.k == 'pipe' and len(item.cmds) == 1:
            item = item.cmds[0]
        return item if item.k in ('if', 'case') else None

    def first_test(self, cond, var):
        if len(cond.items) != 1:
            return None         # the branch runs on the status of the LAST command of the condition
        a = cond.items[0]
        if a.k != 'andor' or a.ops:
            return None         # `[ .. ] || true` and `[ .. ] && x` change the status the branch sees
        sm = self.single_simple_pipe(a.parts[0])
        if sm is None or cmd_name(sm) != '[':
            return None
        args = [word_lit(w) for w in sm.words[1:]]
        if len(args) == 4 and args[3] == ']' and args[1] in ('=', '!=', '-eq', '-ne', '==') and args[2] is not None:
            w = sm.words[1]
            if self.is_var_word(w, var):
                return (args[1], args[2])
        return None

    def single_simple_pipe(self, pipe):
        if pipe.k == 'pipe' and len(pipe.cmds) == 1 and not pipe.neg and pipe.cmds[0].k == 'simple':
            return pipe.cmds[0]
        return None

    def is_var_word(self, w, var):
        if len(w.parts) != 1:
            return False
        p = w.parts[0]
        if isinstance(p, Node) and p.k == 'dq' and len(p.parts) == 1:
            p = p.parts[0]
        return p == ('var', var)

    def v_literal_if(self, item, var):
        it = self.unwrap(item)
        if it is None or it.k != 'if' or len(it.clauses) != 1 or it.els is not None:
            return False
        t = self.first_test(it.clauses[0][0], var)
        if t is None or len(it.clauses[0][0].items) != 1:
            return False
        return t[1] != '0' and self.refusal_list(it.clauses[0][1])

    def ends_success(self, lst):
        if not lst.items:
            return False
        sm = self.single_simple(lst.items[-1])
        if sm is None or cmd_name(sm) not in ('return', 'exit'):
            return False
        return [word_lit(w) for w in sm.words[1:]] == ['0']

    def safe_stmt(self, item):
        sm = self.single_simple(item)
        if sm is not None:
            name = cmd_name(sm)
            if name == 'exec':
                return len(sm.words) == 1
            return name in SAFE_CLEANUP and not any(r.op in ('<', '<>', '<<<') for r in sm.redirs) \
                and not any(d.k in ('cs', 'ps', 'bt') for d in walk(sm))
        it = self.unwrap(item)
        if it is not None and it.k == 'if':
            lists = [c for c, b in it.clauses] + [b for c, b in it.clauses] + ([it.els] if it.els else [])
            return all(self.safe_stmt(x) for lst in lists for x in lst.items) or False
        return False

    def refuses_after(self, items, k):
        rest = items[k + 1:]
        if not rest:
            return False
        if not self.refusal_stmt(rest[-1]):
            return False
        return all(self.safe_stmt(x) for x in rest[:-1])

    def i5(self, case, var, lst, i):
        return self.bad('three outcomes (absent / unreadable / present) need an errno-aware helper: none exists yet')

    def cs_head(self, item):
        for d in walk(item):
            if d.k == 'cs':
                lst = d.body.items
                if len(lst) == 1:
                    sm = self.single_simple_pipe(lst[0].parts[0]) if lst[0].k == 'andor' and len(lst[0].parts) == 1 else None
                    if sm is not None:
                        return cmd_name(sm)
                return None
        return None

    # --- occurrences ---
    def enumerate(self):
        self.occs = []
        for fname, (src, parser, root) in self.files.items():
            for nd in walk(root):
                for kind, node in self.occ_of(fname, nd):
                    o = Occ(fname, kind, node, src[node.start:node.end] if node.end is not None else '')
                    o.line = parser.line(node.start)
                    st = node
                    while st is not None and st.k != 'andor':
                        st = st.parent
                    o.stmt = st
                    self.occs.append(o)
        # statement-relative index
        seen = {}
        for o in sorted(self.occs, key=lambda x: (x.file, x.node.start, x.node.end or 0)):
            key = (o.file, id(o.stmt))
            o.idx = seen.get(key, 0)
            seen[key] = o.idx + 1
            o.key = (o.file, digest(self.text(o.file, o.stmt)) if o.stmt is not None else '-', o.idx)

    def occ_of(self, fname, nd):
        k = nd.k
        if k == 'cs':
            yield 'CS', nd
        elif k == 'ps':
            yield 'PS', nd
        elif k == 'bt':
            yield 'BT', nd
        elif k == 'redir':
            if nd.heredoc:
                return
            if nd.op == '<<<':
                yield 'HERE', nd
            elif nd.op in ('<', '<>'):
                if nd.target is not None and word_lit(nd.target) == '/dev/null':
                    return
                yield 'RDIR', nd
        elif k == 'word' and getattr(nd, 'dbrack', False):
            toks = nd.parts[0][1].split()
            if any(t in FILE_TEST_OPS for t in toks):
                yield 'TEST', nd
        elif k == 'simple':
            if not nd.words:
                return
            name = cmd_name(nd)
            args = [word_lit(w) for w in nd.words[1:]]
            inner = self.nearest_sub(nd) is not None
            if name in self.funcs:
                kind = self.async_call(nd)
                if kind == 'bg':
                    yield 'ACALL', nd
                    return
                if kind == 'pipe' and name not in self.propagating:
                    yield 'FCALL', nd       # judged like any command: does the pipeline's status reach a refusal?
                    return
            if name in self.runner_names():
                yield 'RUNCALL', nd         # a call of the one listed runner: its target is judged where it is called
                return
            if name == '$':
                fn = nd
                while fn is not None and fn.k != 'func':
                    fn = fn.parent
                w0 = self.files[fname][0][nd.words[0].start:nd.words[0].end]
                if w0 == '"$@"' and fn is not None and (fname, fn.name) in self.ENV_RUNNERS:
                    return                  # the listed runner's own body (the envelope holds it to exactly this word)
                yield 'DISPATCH', nd
            elif name == 'command' and len(args) == 2 and args[0] == '-v' and args[1] is not None:
                yield 'TEST', nd
            elif name in FORBIDDEN:
                if name in ('source', '.'):
                    yield 'SRC', nd
                elif name in ('bash', 'sh', 'zsh') and '-c' not in args:
                    return
                else:
                    yield 'DISPATCH', nd
            elif name in ('[', 'test'):
                if any(a in FILE_TEST_OPS for a in args if a is not None):
                    yield 'TEST', nd
            elif name in ('mapfile', 'readarray'):
                yield 'READ', nd
            elif name == 'read':
                if not self.read_from_memory(nd):
                    yield 'READ', nd
            elif name in ('awk', 'gawk', 'mawk', 'sed') and any(
                    re.search(r'getline|system\s*\(|\|\s*getline|print\s*[^;{}]*\|\s*"', word_lit(w) or '') for w in nd.words[1:]):
                yield 'DISPATCH', nd
            elif inner and (name in READERS or name in self.propagating):
                return      # judged with the substitution that holds it
            elif name in READERS:
                if name == 'python3' or name == 'python' or name == 'perl':
                    yield 'OPQ', nd
                else:
                    yield 'RD', nd
            elif name in self.propagating:
                yield 'HCALL', nd

    def runner_names(self):
        """Names of the listed runner functions that are defined in their listed file."""
        return {fn for (f, fn) in self.ENV_RUNNERS if f in self.files and any(df == f for df, _ in self.funcs.get(fn, []))}

    def runcall(self, o):
        """The runner runs whatever it is given, so a call must name a scanned script as its target: \"$HERE/x.sh\" or
        \"$HERE/../bin/x.sh\". The reads inside that script are judged in that script."""
        nd = o.node
        if len(nd.words) < 2:
            return self.bad('the runner is called with no target')
        src = self.files[o.file][0]
        m = self.RE_RUN_TARGET.match(src[nd.words[1].start:nd.words[1].end])
        if m:
            tgt = posixpath.normpath(posixpath.join(posixpath.dirname(o.file), m.group(1)))
            if tgt in self.files and tgt != o.file:     # the pattern already refuses a library: its first character is a letter or digit
                return self.ok('RUN')
        return self.bad('the runner is called with a target that is not a named scanned script')

    def async_call(self, nd):
        """'bg' when this call of a script function runs in the background (whatever it refuses ends that process only and the
        shell goes on); 'pipe' when it is a stage of a pipeline; else None."""
        n, kind = nd, None
        while n is not None:
            if getattr(n, 'bg', False):
                return 'bg'
            p = n.parent
            if p is None or p.k in ('cs', 'ps', 'func', 'script'):
                return kind
            if p.k == 'subshell':
                return 'bg'     # its own process: a refusal in it ends that process only
            if p.k == 'pipe' and len(p.cmds) > 1:
                kind = 'pipe'
            n = p
        return kind

    def read_from_memory(self, sm):
        for r in sm.redirs:
            if r.op == '<<<' or r.heredoc:
                return True
        p = sm.parent
        while p is not None:
            if p.k in ('while', 'for'):
                return any(r.op == '<<<' or r.heredoc for r in p.redirs)
            if p.k in ('cs', 'ps', 'func', 'script'):
                break
            p = p.parent
        return False

    # --- verdicts ---
    def judge(self, o):
        n = o.node
        res = None
        if o.kind == 'BT':
            res = self.bad('backtick substitution')
        elif o.kind == 'PS':
            res = self.bad('a process substitution: its status is never seen')
        elif o.kind == 'CS':
            res = self.cs_value(n, 'F')
            inner = self.inner_verdict(n)
            if inner is not None:
                res = inner
        elif o.kind == 'ACALL':
            res = self.bad('a script function is called in the background: its refusal ends only that process')
        elif o.kind == 'RUNCALL':
            res = self.runcall(o)
        elif o.kind == 'DISPATCH':
            res = self.bad('dispatch through a variable, eval, xargs, command or a shell -c string cannot be audited')
        elif o.kind == 'HERE':
            res = self.here(o)
        elif o.kind == 'RDIR':
            owner = n.parent
            if owner.k == 'simple':
                res = self.consume(owner)
            else:
                res = self.bad('a file feeding a loop or group: its open status is lost (snapshot it with an I1 capture)')
        elif o.kind == 'TEST':
            res = self.bad('a metadata test cannot tell absent from unreadable')
            if n.k == 'simple' and cmd_name(n) in ('[', 'test'):
                args = [word_lit(w) for w in n.words[1:]]
                ops = [a for a in args if a in FILE_TEST_OPS]
                if len(ops) == 1 and '!' not in args and '-a' not in args and '-o' not in args and '(' not in args:
                    r = self.consume(n)
                    if r[0] == 'OK' and r[1] == 'REFUSE':
                        res = self.ok('CK')
        elif o.kind == 'READ':
            res = self.bad('read returns 1 for end of input and for an error alike')
        elif o.kind == 'OPQ':
            res = self.bad('opaque program: its text must be pinned')
        else:
            sm = n
            res = self.consume(sm)
            if res[0] == 'OK' and cmd_name(sm) in TRISTATE:
                res = self.bad('%s exits 1 for no match: a result, not a failure' % cmd_name(sm))
            if res[0] == 'OK' and res[1] == 'REFUSE':
                pipe = sm.parent
                if pipe.k == 'pipe' and len(pipe.cmds) > 1 and pipe.cmds.index(sm) < len(pipe.cmds) - 1:
                    res = self.ok('I2')
                else:
                    res = self.ok('CK')
        status, label, needs, func = res
        if o.kind == 'CS' and status == 'OK' and label == 'REFUSE':
            label = 'I1'
        if status == 'OK' and label == 'REFUSE':
            label = 'CK'
        o.status, o.needs, o.func = status, needs, func
        if status == 'OK':
            o.label, o.why = label, ''
        else:
            o.label, o.why = '', label
        return o

    def inner_cmds(self, cs):
        out = []

        def rec(x):
            for c in x.kids():
                if c.k in ('cs', 'ps', 'func'):
                    continue
                if c.k == 'simple' and c.words:
                    name = cmd_name(c)
                    if name in READERS or name in self.propagating:
                        out.append(c)
                rec(c)
        rec(cs.body)
        return out

    def inner_verdict(self, cs):
        """The first reader inside a substitution whose own failure is lost before it reaches the substitution status."""
        for c in self.inner_cmds(cs):
            r = self.consume(c, 'F', stop=cs)
            if r[0] == 'BAD':
                return r
            if cmd_name(c) in TRISTATE:
                return self.bad('%s exits 1 for no match: a result, not a failure' % cmd_name(c))
        return None

    def here(self, o):
        n = o.node
        t = n.target
        owner = n.parent
        if t is None or not self.is_var_word(t, t.parts[0][1] if t.parts and isinstance(t.parts[0], tuple) else '') and not (
                len(t.parts) == 1 and isinstance(t.parts[0], Node) and t.parts[0].k == 'dq'):
            pass
        var = None
        if t is not None and len(t.parts) == 1:
            p = t.parts[0]
            if isinstance(p, Node) and p.k == 'dq' and len(p.parts) == 1:
                p = p.parts[0]
            if isinstance(p, tuple) and p[0] == 'var':
                var = p[1]
        if var is None:
            return self.bad('here-string source is not a plain variable')
        node = owner
        lst = None
        while node is not None:
            if node.parent is not None and node.parent.k == 'list' and node in node.parent.items:
                lst = node.parent
                break
            node = node.parent
        # climb through enclosing lists, looking for the last assignment of var before the loop
        item = node
        while lst is not None:
            idx = lst.items.index(item)
            for j in range(idx - 1, -1, -1):
                other = lst.items[j]
                sm = self.single_simple(other)
                if sm is None and other.k == 'andor' and other.parts[0].k == 'pipe' and len(other.parts[0].cmds) == 1 \
                        and other.parts[0].cmds[0].k == 'simple' and not other.parts[0].neg:
                    first = other.parts[0].cmds[0]
                    if any(a.name == var for a in first.assigns) and not any(
                            d.k == 'simple' and d is not first and any(a.name == var for a in d.assigns) for d in walk(other)):
                        sm = first
                if sm is None:
                    for d in walk(other):
                        if d.k == 'simple' and any(a.name == var for a in d.assigns):
                            return self.bad('the variable is reassigned in a statement that is not a plain capture')
                    continue
                if any(a.name == var for a in sm.assigns):
                    if sm.words:
                        return self.bad('the variable is assigned in front of a command')
                    cs = [d for a in sm.assigns if a.name == var for d in walk(a.value) if d.k == 'cs']
                    if len(cs) != 1:
                        return self.bad('the variable is not filled by one command substitution')
                    r = self.consume(sm)
                    if r[0] == 'OK' and r[1] == 'REFUSE':
                        return self.ok('I4')
                    return self.bad('the variable was filled by an unchecked capture')
            nxt = lst.parent
            if nxt is None or nxt.k in ('func', 'script', 'cs', 'ps', 'subshell'):
                break
            item = nxt
            while item is not None and not (item.parent is not None and item.parent.k == 'list' and item in item.parent.items):
                item = item.parent
            if item is None:
                break
            lst = item.parent
        return self.bad('no checked capture of the variable before the loop')

    def run(self):
        self.validate()
        if self.envelope_on:
            self.envelope()
        self.compute_helpers()
        self.propagating = set()
        for _ in range(12):
            self.enumerate()
            for o in self.occs:
                self.judge(o)
            new = set(o.func for o in self.occs if o.status == 'OK' and o.func and len(self.funcs.get(o.func, [])) == 1)
            if new <= self.propagating:
                break
            self.propagating |= new
        # a helper call is judged like any command; the helper itself keeps the OK:PROP of its last read
        for o in self.occs:
            if o.status == 'OK' and o.label == 'PROP':
                o.label = 'PROP'
        if self.envelope_on:
            for o in self.occs:
                o.envelope = o.file in self.env_files
                if o.envelope and o.status != 'BAD':
                    o.status, o.label = 'BAD', ''
                    o.why = 'the file is outside the envelope (%s)' % self.env_why[o.file]
            seq = {}
            for f, line, rule, why in self.env:
                seq[f] = seq.get(f, 0) + 1
                eo = Occ(f, 'ENVELOPE', None, why)
                eo.status, eo.why, eo.line, eo.envelope = 'BAD', 'ENVELOPE %s: %s' % (rule, why), line, True
                eo.key = (f, 'envelope-%s' % rule, seq[f])
                self.occs.append(eo)
        return self.occs


# ----------------------------------------------------------------------------------------------------------------------
# The allow file: exact occurrence, reason code, contract checked by the scanner
# ----------------------------------------------------------------------------------------------------------------------


class Entry:
    def __init__(self, file, stmt, idx, reason, ctx, note, lineno):
        self.file, self.stmt, self.idx, self.reason, self.ctx, self.note, self.lineno = file, stmt, idx, reason, ctx, note, lineno
        self.matched = []
        self.problem = None


def load_allow(text, where='allow file'):
    out = []
    for no, ln in enumerate(text.splitlines(), 1):
        if not ln.strip() or ln.lstrip().startswith('#'):
            continue
        f = ln.split('\t')
        if len(f) < 5 or f[3] not in REASONS or not re.fullmatch(r'[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}', f[1]) or not f[2].isdigit():
            raise ParseError('%s line %d: expected file<TAB>hash<TAB>index<TAB>REASON<TAB>ctx<TAB>note' % (where, no))
        out.append(Entry(f[0], f[1], int(f[2]), f[3], f[4], f[5] if len(f) > 5 else '', no))
    return out


class Contracts:
    """What a reason code means for an occurrence. The allow file only names the occurrence; this decides."""

    def __init__(self, an):
        self.an = an

    OUT_OPS = ('>', '>>', '>|', '&>', '&>>', '<>')

    def check(self, o, e):
        if o.kind == 'ENVELOPE' or getattr(o, 'envelope', False):
            return 'the file is outside the envelope: nothing in it can be listed'
        if o.kind == 'DISPATCH':
            return 'a dispatch line cannot be listed: nothing says what it runs, whatever the reason'
        why = self.enclosing(o)
        if why:
            return why
        fn = getattr(self, 'c_' + e.reason)
        return fn(o, e)

    @staticmethod
    def file_out(r):
        """True when the redirection can send output to a file: any output operator but /dev/null, and a duplication onto a
        descriptor other than 1, 2 or a close (descriptor 3 may be a file, and a computed target is unknown)."""
        t = word_lit(r.target) if r.target is not None else None
        if r.op in Contracts.OUT_OPS:
            return t != '/dev/null'
        if r.op == '>&':
            return t not in ('1', '2', '-')
        return False

    def enclosing(self, o):
        """Every reason holds only for the statement as written in its place: nothing around it may send its output to a file,
        make it a stage of a pipeline, or run it in the background. (The entry is bound to the statement's text; this binds it
        to where the statement sits, so moving it into a redirected group or a pipe voids the entry.) A statement in a function
        is where each call of that function puts it; a display reason also needs the shell's own descriptors untouched."""
        return self.climb(o.node, o.node, 0, False)

    def climb(self, start, self_node, depth, capture):
        n = start
        while n is not None and n.k not in ('func', 'script'):
            p = n.parent
            if p is None:
                break
            if p.k == 'pipe' and len(p.cmds) > 1 and not (n.k == 'simple' and n is self_node):
                return 'the statement is a stage of a pipeline: its output may go anywhere'
            if getattr(n, 'bg', False) and n is not self_node:
                return 'the statement runs in the background'
            if capture and p.k in ('cs', 'ps', 'bt'):
                return 'the output of this statement is captured by a substitution, not shown'
            for r in getattr(p, 'redirs', None) or ():
                if self.file_out(r):
                    return 'an enclosing %s sends its output to a file (%s)' % (p.k, r.op)
            n = p
        if n is not None and n.k == 'func':
            return self.call_sites(n, depth, capture)
        return None

    def call_sites(self, fn, depth, capture):
        """A function's statements run where it is called: every call must be a plain place (no own redirection, no pipe)."""
        if depth > 6:
            return 'functions call each other too deeply to follow'
        fname = self.an.fname_of(fn)
        calls = []
        for g in sorted(self.an.component(fname) | {fname}):
            for d in walk(self.an.files[g][2]):
                if d.k == 'simple' and d.words and unwrapped(d)[0] == fn.name and not any(a is fn for a in self.an.ancestors(d)):
                    calls.append(d)
        for t, c in self.trap_calls(fname, fn.name):
            # a call inside a literal trap action runs wherever the signal lands: judged like any call, in the action's own text
            n = c
            while n is not None:
                if any(self.file_out(r) for r in getattr(n, 'redirs', None) or ()):
                    return 'a call of %s in a trap action sends its output to a file' % fn.name
                if n.k == 'pipe' and len(n.cmds) > 1:
                    return 'a call of %s in a trap action is a stage of a pipeline' % fn.name
                n = n.parent
            why = self.climb(t, None, depth + 1, capture)
            if why:
                return why
        for c in calls:
            if any(self.file_out(r) for r in c.redirs):
                return 'a call of %s sends its output to a file' % fn.name
            why = self.climb(c, None, depth + 1, capture)
            if why:
                return why
        return None

    def trap_calls(self, fname, name):
        """(trap statement, call node) for every call of the function inside a literal trap action in this file's component."""
        out = []
        for g in sorted(self.an.component(fname) | {fname}):
            for d in walk(self.an.files[g][2]):
                if d.k != 'simple' or not d.words or unwrapped(d)[0] != 'trap':
                    continue
                args = unwrapped(d)[1]
                if args and args[0] == '--':
                    args = args[1:]
                if len(args) < 2 or args[0] is None or args[0] in ('-', '-p', '-l'):
                    continue
                try:
                    tree = Parser(args[0]).parse_script()
                except ParseError:
                    continue
                link(tree)
                out.extend((d, c) for c in walk(tree) if c.k == 'simple' and c.words and unwrapped(c)[0] == name)
        return out

    def stmt_text(self, o):
        return self.an.text(o.file, o.stmt) if o.stmt is not None else ''

    def outer_simple(self, o):
        n = o.node
        while n is not None and n.k != 'simple':
            n = n.parent
        return n

    def c_K(self, o, e):
        if o.kind != 'CS':
            return 'K is for a command substitution'
        lst = o.node.body.items
        if len(lst) != 1:
            return 'K substitution has more than one statement'
        sm = self.an.single_simple(lst[0])
        if sm is None or cmd_name(sm) != 'printf' or [word_lit(w) for w in sm.words[1:]] not in (['\\t'], ['\\n']):
            return 'K substitution is not printf of a literal tab'
        return None

    def c_H(self, o, e):
        if o.kind != 'RD' or cmd_name(o.node) != 'sed':
            return 'H is for the two sed commands that print the help text'
        pipe = o.node.parent
        if pipe.k != 'pipe' or len(pipe.cmds) != 2:
            return 'H needs the two-stage help pipeline'
        a = [word_lit(w) for w in pipe.cmds[0].words]
        b = [word_lit(w) for w in pipe.cmds[1].words]
        okA = len(a) == 4 and a[0] == 'sed' and a[1] == '-n' and re.fullmatch(r"[0-9]+,[0-9]+p", a[2] or '') and word_lit(pipe.cmds[0].words[3]) is None \
            and self.dollar0(pipe.cmds[0].words[3])
        okB = b == ['sed', 's/^# \\{0,1\\}//']
        if not (okA and okB):
            return 'H pipeline is not sed -n N,Mp "$0" | sed s/^# \\{0,1\\}//'
        return None

    def dollar0(self, w):
        p = w.parts[0] if len(w.parts) == 1 else None
        if isinstance(p, Node) and p.k == 'dq' and len(p.parts) == 1:
            p = p.parts[0]
        return p == ('var', '0')

    def c_M(self, o, e):
        if o.kind != 'RD' or cmd_name(o.node) != 'cat' or len(o.node.words) != 1:
            return 'M is for a bare cat that drains stdin'
        reds = [(r.op, word_lit(r.target) if r.target is not None else None, r.fd) for r in o.node.redirs]
        if ('>', '/dev/null', '') not in reds:
            return 'M cat must send its output to /dev/null'
        return None

    def nearest_cs(self, n):
        p = n.parent
        while p is not None and p.k not in ('cs', 'func', 'script'):
            p = p.parent
        return p if p is not None and p.k == 'cs' else None

    def display_stmt(self, o):
        """The value is printed by an echo/printf (climbing out of nested substitutions that are arguments). That printing
        statement must itself sit in a plain place: not captured by a substitution, no redirection to a file, no pipe. The one
        capture accepted is the stored hint `NAME=$(printf ...)`, a printf that is the whole body of the substitution."""
        sm = self.outer_simple(o)
        while sm is not None:
            if sm.words and cmd_name(sm) in ('echo', 'printf') and not any(self.file_out(r) or r.op == '<' for r in sm.redirs):
                cs = self.nearest_cs(sm)
                if cs is None:
                    return self.climb(sm, None, 0, True) is None
                owner = self.outer_simple_of(cs)
                if (cmd_name(sm) == 'printf' and len(cs.body.items) == 1 and self.an.single_simple(cs.body.items[0]) is sm
                        and owner is not None and not owner.words and len(owner.assigns) == 1 and not owner.redirs):
                    return self.climb(owner, None, 0, False) is None
                sm = owner
                continue
            cs = self.nearest_cs(sm)
            if cs is None:
                break
            sm = self.outer_simple_of(cs)
        return False

    def outer_simple_of(self, n):
        while n is not None and n.k != 'simple':
            n = n.parent
        return n

    def c_D(self, o, e):
        if o.kind == 'CS':
            lst = o.node.body.items
            if len(lst) != 1:
                return 'D substitution has more than one statement'
            sm = self.an.single_simple(lst[0])
            if sm is not None and cmd_name(sm) == 'date':
                if [word_lit(w) for w in sm.words[1:]] not in (['+%H:%M'], ['+%H:%M:%S']):
                    return 'D allows only date +%H:%M and +%H:%M:%S'
            elif sm is not None and cmd_name(sm) == 'printf':
                if word_lit(sm.words[1]) != '%q':
                    return 'D allows printf %q only'
            else:
                a = lst[0]
                if not (a.k == 'andor' and a.ops == ['&&'] and len(a.parts) == 2):
                    return 'D substitution is not a display builder'
                c0 = self.an.single_simple_pipe(a.parts[0])
                c1 = self.an.single_simple_pipe(a.parts[1])
                if not (c0 is not None and c1 is not None and cmd_name(c0) == 'cd' and cmd_name(c1) == 'pwd'):
                    return 'D allows cd DIR && pwd only'
        else:
            return 'D is for a command substitution'
        if not self.display_stmt(o):
            return 'D value must be printed by echo or printf (no file redirect)'
        return None

    def c_X(self, o, e):
        if o.kind != 'CS':
            return 'X is for a command substitution'
        for d in walk(o.node):
            if d.k == 'redir' and d.op in ('>', '>>', '>|', '&>') and word_lit(d.target) != '/dev/null':
                owner = d.parent
                if not (owner is not None and owner.k == 'simple' and cmd_name(owner) == ':' and d.op == '>>'):
                    return 'X substitution writes somewhere other than a null-command probe'
        if not self.display_stmt(o):
            return 'X value must be printed by echo or printf'
        sm = self.outer_simple(o)
        lst = sm.parent
        while lst is not None and lst.k != 'list':
            lst = lst.parent
        items = lst.items
        k = items.index(o.stmt) if o.stmt in items else -1
        if k < 0 or k != len(items) - 2 or not self.an.refusal_stmt(items[-1]):
            return 'X message must be followed by return or exit and nothing else'
        return None

    def c_V(self, o, e):
        if 'V' not in o.needs:
            return 'V is for a read whose status is the script exit status'
        if o.kind not in ('RD',):
            return 'V is for a plain reader command'
        sm = o.node
        pipe = sm.parent
        if pipe.k != 'pipe':
            return 'V read is not a command of a pipeline'
        if any(r.op in ('>', '>>') and word_lit(r.target) not in ('/dev/null', '&2', '2') for r in sm.redirs):
            return 'V read writes to a file'
        if len(pipe.cmds) > 1:
            for c in pipe.cmds:
                if c.k != 'simple' or cmd_name(c) in TRISTATE:
                    return 'V pipeline has a stage that is not a plain command, or a grep'
            if not self.an.pipefail_active(pipe):
                return 'V pipeline has no set -o pipefail'
        for d in walk(pipe):
            if d.k in ('cs', 'ps', 'bt'):
                return 'V read contains a substitution'
        n = pipe
        while n.parent is not None:
            p = n.parent
            if p.k == 'andor' and len(p.parts) != 1:
                return 'V read is part of a && / || chain'
            if p.k in ('cs', 'ps', 'subshell', 'func'):
                return 'V read is inside a substitution, subshell or function'
            if p.k == 'list' and p.items.index(n) != len(p.items) - 1:
                return 'V read is followed by another statement'
            if p.k == 'case':
                pass
            if p.k == 'pipe' and len(p.cmds) > 1:
                return 'V read is nested in a pipeline'
            n = p
        return None

    def c_C(self, o, e):
        if 'C' not in o.needs:
            return 'C is for a read whose failure branch is continue'
        loop = None
        n = o.node.parent
        while n is not None:
            if n.k in ('while', 'for'):
                loop = n
                break
            if n.k in ('func', 'cs', 'ps', 'script'):
                break
            n = n.parent
        if loop is None:
            return 'continue is not inside a loop'
        header = self.an.text(o.file, loop).split('\n')[0]
        if digest(header) != e.ctx:
            return 'the nearest loop is not the one the entry names'
        for d in walk(o.stmt):
            if d.k == 'simple' and cmd_name(d) == 'continue' and len(d.words) != 1:
                return 'continue with a count'
        return None

    def c_P(self, o, e):
        if o.kind != 'TEST':
            return 'P is for a metadata test'
        operand = self.operand(o)
        if not operand:
            return 'P test has no operand'
        fn = o.node
        while fn is not None and fn.k not in ('func', 'script'):
            fn = fn.parent
        for other in self.an.occs:
            if other is o or other.kind != 'TEST' or other.file != o.file or other.node.start <= o.node.end:
                continue
            f2 = other.node
            while f2 is not None and f2.k not in ('func', 'script'):
                f2 = f2.parent
            if f2 is not fn or self.operand(other) != operand:
                continue
            if other.status == 'OK' and other.label == 'CK':
                return None
            st = other.stmt
            if st is None:
                continue
            sm = st
            if sm.parent.k == 'list':
                it = self.an.unwrap(st)
                lst = sm.parent
                k = lst.items.index(st)
                if it is not None and it.k == 'if' and self.an.refusal_list(it.clauses[0][1]):
                    return None
                if self.an.refuses_after(lst.items, k):
                    return None
            return 'P recheck of the same operand does not refuse'
        return 'P needs a later test of the same operand in the same function that ends in a refusal'

    def operand(self, o):
        n = o.node
        if n.k == 'word':
            toks = n.parts[0][1].split()
            return ' '.join(t for t in toks[1:-1] if t not in FILE_TEST_OPS and t not in ('!', '&&', '||'))
        args = [self.an.files[o.file][0][w.start:w.end] for w in n.words[1:]]
        return ' '.join(a for a in args if a not in FILE_TEST_OPS and a not in ('!', ']', '-o', '-a'))

    def c_O(self, o, e):
        if o.kind == 'OPQ':
            sm = o.node
        elif o.kind == 'CS':
            lst = o.node.body.items
            sm = self.an.single_simple(lst[0]) if len(lst) == 1 else None
            if sm is None or cmd_name(sm) not in ('python3', 'python'):
                return 'O substitution must be one python3 program'
        else:
            return 'O is for python3 programs'
        args = [word_lit(w) for w in sm.words[1:]]
        if '-I' not in args or '-c' not in args:
            return 'O program must run isolated (-I) with -c'
        ci = args.index('-c')
        if ci + 1 >= len(args) or args[ci + 1] is None:
            return 'O program text must be one literal'
        if digest(args[ci + 1]) != e.ctx:
            return 'O program text changed: pin %s' % digest(args[ci + 1])
        return None


def apply_allow(an, entries):
    """Match each entry to exactly one occurrence, then check the reason contract. Returns (dead, invalid, ambiguous)."""
    by_key = {}
    for o in an.occs:
        by_key.setdefault(o.key, []).append(o)
    ct = Contracts(an)
    seen = {}
    dead, invalid, ambiguous = [], [], []
    for e in entries:
        k = (e.file, e.stmt, e.idx)
        if k in seen:
            e.problem = 'duplicate of line %d' % seen[k]
            ambiguous.append(e)
            continue
        seen[k] = e.lineno
        occs = by_key.get(k, [])
        if not occs:
            e.problem = 'matches no occurrence (the statement changed or moved)'
            dead.append(e)
            continue
        if len(occs) > 1:
            e.problem = 'matches %d occurrences' % len(occs)
            ambiguous.append(e)
            continue
        o = occs[0]
        e.matched = [o]
        if o.status == 'OK':
            e.problem = 'the occurrence is already accepted (%s): the entry is not needed' % o.label
            dead.append(e)
            continue
        why = ct.check(o, e)
        if why:
            e.problem = why
            invalid.append(e)
            continue
        o.listed = e.reason
    return dead, invalid, ambiguous


def ctx_for(an, o, r):
    """The binding text a reason needs: the loop header for C, the program text for O."""
    if r == 'C':
        lp = o.node
        while lp is not None and lp.k not in ('while', 'for'):
            lp = lp.parent
        if lp is not None:
            return digest(an.text(o.file, lp).split('\n')[0])
    if r == 'O':
        sm = o.node if o.kind == 'OPQ' else (an.single_simple(o.node.body.items[0]) if o.kind == 'CS' and len(o.node.body.items) == 1 else None)
        if sm is not None and sm.k == 'simple':
            args = [word_lit(w) for w in sm.words[1:]]
            if '-c' in args:
                i = args.index('-c')
                if i + 1 < len(args) and args[i + 1] is not None:
                    return digest(args[i + 1])
    return '-'


def propose(an):
    """Allow-file lines for every unlisted occurrence that a reason contract accepts (a maintainer reviews them)."""
    ct = Contracts(an)
    out = []
    for o in an.occs:
        if o.status != 'BAD' or o.listed:
            continue
        for r in 'KHMDXVCPO':
            ctx = ctx_for(an, o, r)
            e = Entry(o.file, o.key[1], o.key[2], r, ctx, '', 0)
            if ct.check(o, e) is None:
                out.append('%s\t%s\t%d\t%s\t%s\t%s' % (o.file, o.key[1], o.key[2], r, ctx, ' '.join(o.text.split())[:70]))
                break
    return out


def duplicate_statements(an):
    """Two identical statements in one file would share a hash: the entry must name exactly one location."""
    seen = {}
    out = []
    for o in an.occs:
        if o.stmt is None:
            continue
        k = (o.file, digest(an.text(o.file, o.stmt)), o.idx)
        seen.setdefault(k, set()).add(id(o.stmt))
    for k, ids in seen.items():
        if len(ids) > 1:
            out.append(k)
    return out


# ----------------------------------------------------------------------------------------------------------------------
# Running over a tree, reporting
# ----------------------------------------------------------------------------------------------------------------------


def tree_files(root):
    """The gate's universe: bin/*.sh and hooks/*.sh. Anything else under bin/ or hooks/ is reported by tree_out, never skipped."""
    out = []
    for d in ('bin', 'hooks'):
        p = os.path.join(root, d)
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                fp = os.path.join(p, f)
                if f.endswith('.sh') and os.path.isfile(fp) and not os.path.islink(fp):
                    out.append(os.path.join(d, f))
    return out


def tree_out(root):
    """Every path under bin/ and hooks/ that is not a plain *.sh file at the top of the folder (subfolder files, extensionless
    scripts, *.bash, symlinks, anything else): the repo must not grow a script the gate does not see."""
    out = []
    for d in ('bin', 'hooks'):
        p = os.path.join(root, d)
        if not os.path.isdir(p):
            continue
        for dirpath, dirs, names in os.walk(p, followlinks=False):
            dirs.sort()
            rel = os.path.relpath(dirpath, root)
            for n in sorted(names + [x for x in dirs if os.path.islink(os.path.join(dirpath, x))]):
                fp = os.path.join(dirpath, n)
                path = os.path.join(rel, n)
                if os.path.islink(fp):
                    out.append((path, 'a symlink: the gate reads plain files only'))
                elif not os.path.isfile(fp):
                    out.append((path, 'not a plain file'))
                elif rel != d:
                    out.append((path, 'a file in a subfolder of %s/ is never read by the gate' % d))
                elif not n.endswith('.sh'):
                    out.append((path, 'a file in %s/ that is not *.sh is never read by the gate' % d))
    return out


def analyze_files(root, files, envelope=True):
    an = Analyzer()
    an.envelope_on = envelope
    an.out_files = tree_out(root) if envelope else []
    for f in files:
        with open(os.path.join(root, f), encoding='utf-8') as fh:
            an.add(f, fh.read())
    an.run()
    return an


def kind_of(o):
    return o.kind


def summarize(an, entries, dead, invalid, ambiguous):
    occs = an.occs
    unlisted = [o for o in occs if o.status == 'BAD' and not o.listed]
    listed = [o for o in occs if o.listed]
    ok = [o for o in occs if o.status == 'OK']
    return occs, ok, listed, unlisted


def report(an, entries, dead, invalid, ambiguous, verbose=False, tsv=None, out=sys.stdout):
    occs, ok, listed, unlisted = summarize(an, entries, dead, invalid, ambiguous)
    kinds = {}
    for o in occs:
        kinds[o.kind] = kinds.get(o.kind, 0) + 1
    out.write('read-gate (report mode): files=%d occurrences=%d classes=%d unlisted=%d listed=%d ok=%d dead=%d invalid=%d ambiguous=%d%s\n'
              % (len(an.files), len(occs), len(kinds), len(unlisted), len(listed), len(ok), len(dead), len(invalid), len(ambiguous),
                 '' if an.envelope_on else ' envelope=off'))
    out.write('  classes: %s\n' % ', '.join('%s=%d' % (k, kinds[k]) for k in sorted(kinds)))
    st = {}
    for o in occs:
        lab = ('OK:' + o.label) if o.status == 'OK' else ('LISTED:' + o.listed if o.listed else 'UNLISTED')
        st[lab] = st.get(lab, 0) + 1
    out.write('  status:  %s\n' % ', '.join('%s=%d' % (k, st[k]) for k in sorted(st)))
    why = {}
    for o in unlisted:
        why[o.why] = why.get(o.why, 0) + 1
    for w, c in sorted(why.items(), key=lambda x: -x[1]):
        out.write('  unlisted %3d  %s\n' % (c, w))
    for e in dead + invalid + ambiguous:
        out.write('  allow-file entry line %d (%s %s): %s\n' % (e.lineno, e.file, e.reason, e.problem))
    if verbose:
        for o in occs:
            lab = ('OK:' + o.label) if o.status == 'OK' else ('LISTED:' + o.listed if o.listed else 'UNLISTED: ' + o.why)
            out.write('%s:%d\t%s\t%s\t%s\n' % (o.file, o.line, o.kind, lab, ' '.join(o.text.split())[:90]))
    if tsv:
        with open(tsv, 'w', encoding='utf-8') as fh:
            fh.write('file\tline\tclass\tstatus\tstatement_hash\tindex\ttext\n')
            for o in occs:
                lab = ('OK:' + o.label) if o.status == 'OK' else ('LISTED:' + o.listed if o.listed else 'UNLISTED: ' + o.why)
                fh.write('%s\t%d\t%s\t%s\t%s\t%d\t%s\n' % (o.file, o.line, o.kind, lab, o.key[1], o.idx, ' '.join(o.text.split())[:120]))
    return len(unlisted) + len(dead) + len(invalid) + len(ambiguous)


# ----------------------------------------------------------------------------------------------------------------------
# Self-test: fixtures, counterexamples, mutants
# ----------------------------------------------------------------------------------------------------------------------

FIX_DIR = 'read-gate-fixtures'


def parse_header(text):
    exp, allows, minocc = None, [], 1
    for ln in text.splitlines():
        m = re.match(r'#\s*expect:\s*(pass|fail|error)\s*(.*)$', ln)
        if m:
            exp = (m.group(1), [x.strip() for x in m.group(2).split(',') if x.strip()])
        m = re.match(r'#\s*allow:\s*([A-Z])\s+line=(\d+)(?:\s+idx=(\d+))?(?:\s+loop=(\d+))?', ln)
        if m:
            allows.append((m.group(1), int(m.group(2)), int(m.group(3) or 0), int(m.group(4)) if m.group(4) else None))
        m = re.match(r'#\s*min-occurrences:\s*(\d+)', ln)
        if m:
            minocc = int(m.group(1))
    return exp, allows, minocc


def fixture_identity(name, text):
    """A fixture with a `# envelope: bin/x.sh` header is analyzed as that path, with the file envelope on."""
    m = re.search(r'^#\s*envelope:\s*(\S+)', text, re.M)
    return (m.group(1), True) if m else (name, False)


def bind_entries(name, text, allows):
    """Build allow entries from a fixture's header against its own text (line numbers are the fixture's)."""
    name, env = fixture_identity(name, text)
    an = Analyzer()
    an.envelope_on = env
    an.add(name, text)
    an.run()
    out = []
    for reason, line, idx, loop in allows:
        cand = [o for o in an.occs if o.line == line]
        cand.sort(key=lambda o: o.node.start)
        if idx >= len(cand):
            raise ParseError('%s: allow line=%d idx=%d names no occurrence' % (name, line, idx))
        o = cand[idx]
        out.append(Entry(name, o.key[1], o.key[2], reason, ctx_for(an, o, reason), '', 0))
    return out


def run_text(name, text, entries=None):
    """Analyze one script text; returns (an, dead, invalid, ambiguous, unlisted)."""
    name, env = fixture_identity(name, text)
    an = Analyzer()
    an.envelope_on = env
    an.add(name, text)
    an.run()
    dead, invalid, ambiguous = apply_allow(an, entries or [])
    unlisted = [o for o in an.occs if o.status == 'BAD' and not o.listed]
    return an, dead, invalid, ambiguous, unlisted


def diagnostics(an, dead, invalid, ambiguous, unlisted):
    out = [o.why for o in unlisted]
    out += [e.problem for e in dead + invalid + ambiguous]
    return out


# Mutants: (id, fixture, old text, new text, a substring the gate must print for the mutant).
# A want that starts with "@" re-binds the fixture's allow entries to the mutated text first: that isolates the reason
# contract (the entry names the same place, the change breaks what the reason promises). Without "@" the entries come
# from the pristine text, so any change to the statement itself must make the entry dead.
MUTANTS = [
    # same read, different control context -> FAIL
    ('i1-fallback', 'pos_i1_exit.sh', '|| exit 1', '|| true', 'falls back'),
    ('i1-default', 'pos_i1_exit.sh', '|| exit 1', '|| x=0', 'falls back'),
    ('i1-echo', 'pos_i1_exit.sh', '|| exit 1', '|| echo none', 'falls back'),
    ('i1-no-check', 'pos_i1_exit.sh', ' || exit 1', '', 'statement after it'),
    ('i1-exit-zero', 'pos_i1_exit.sh', '|| exit 1', '|| exit 0', 'falls back'),
    ('i1-subshell-exit', 'pos_i1_exit.sh', '|| exit 1', '|| ( exit 1 )', 'falls back'),
    ('i1-bare-exit-after-echo', 'pos_i1_exit.sh', '|| exit 1', '|| { echo failed >&2; exit; }', 'falls back'),
    ('i1-bare-exit-alone-control', 'pos_i1_exit.sh', '|| exit 1', '|| exit', 'ok'),
    ('i1-bare-exit-group-control', 'pos_i1_exit.sh', '|| exit 1', '|| { exit; }', 'ok'),
    ('i1-conditional-terminal', 'pos_i1_exit.sh', '|| exit 1', '|| { [ -n "$F" ] && exit 1; }', 'falls back'),
    ('i1-unreachable-terminal', 'pos_i1_exit.sh', '|| exit 1', '|| { exit 1; echo x; }', 'falls back'),
    ('i1-background-refusal', 'pos_i1_exit.sh', '|| exit 1', '|| exit 1 &', 'another process'),
    ('i1-group-pipe-stage', 'pos_i1_exit.sh', 'x=$(cat "$F") || exit 1', '{ x=$(cat "$F") || exit 1; } | cat', 'another process'),
    ('i1-refusal-in-subshell', 'pos_i1_exit.sh', 'x=$(cat "$F") || exit 1', '( x=$(cat "$F") || exit 1 )', 'another process'),
    ('i1-toplevel-return', 'pos_i1_exit.sh', '|| exit 1', '|| return 1', 'falls back'),
    ('i1-exit-trap-rewrites', 'pos_i1_exit.sh', 'F=${1:-}', "trap 'exit 0' EXIT; F=${1:-}", 'hides or redefines'),
    ('i1-exit-trap-cleanup-control', 'pos_i1_exit.sh', 'F=${1:-}', "trap 'rm -f x' EXIT; F=${1:-}", 'ok'),
    ('i1-exit-function-shadow', 'pos_i1_exit.sh', 'F=${1:-}', 'exit() { echo nope; }; F=${1:-}', 'hides or redefines'),
    ('i1-unset-function', 'pos_i1_exit.sh', 'F=${1:-}', 'unset -f die; F=${1:-}', 'hides or redefines'),
    ('i1-alias', 'pos_i1_exit.sh', 'F=${1:-}', 'alias exit=true; F=${1:-}', 'hides or redefines'),
    ('i1-masked-sequence', 'pos_i1_exit.sh', 'x=$(cat "$F")', 'x=$(cat "$F"; echo done)', 'statement after it'),
    ('i1-or-in-body', 'pos_i1_exit.sh', 'x=$(cat "$F")', 'x=$(cat "$F" || echo none)', 'falls back'),
    ('i1-declaration', 'pos_i1_exit.sh', 'x=$(cat "$F") || exit 1', 'local x=$(cat "$F") || exit 1', 'declaration builtin'),
    ('i1-export', 'pos_i1_exit.sh', 'x=$(cat "$F") || exit 1', 'export x=$(cat "$F") || exit 1', 'declaration builtin'),
    ('i1-argument', 'pos_i1_exit.sh', 'x=$(cat "$F") || exit 1', 'echo "$(cat "$F")" || exit 1', 'argument'),
    ('i1-two-substitutions', 'pos_i1_exit.sh', 'x=$(cat "$F")', 'x=$(cat "$F") y=$(cat "$F")', 'more than one substitution'),
    ('i1-semicolon', 'pos_i1_exit.sh', ' || exit 1\n', '; [ -n "$x" ] || exit 1\n', 'statement after it'),
    ('i1-armfail-returns', 'pos_i1_armfail.sh', 'exit 1; }', 'return 0; }', 'falls back'),
    ('i1-armfail-no-exit', 'pos_i1_armfail.sh', 'echo "$1" >&2; exit 1; }', 'echo "$1" >&2; }', 'falls back'),
    ('i1-if-body-not-refusing', 'pos_i1_if.sh', 'exit 1', 'echo bad', 'does not refuse'),
    ('i1-if-not-negated', 'pos_i1_if.sh', 'if ! x=$(cat "$F"); then', 'if x=$(cat "$F"); then', 'falls through'),
    ('i2-pipefail-turned-off', 'pos_i2_pipefail.sh', 'set -o pipefail; ', 'set -o pipefail; set +o pipefail; ', 'pipeline stage'),
    ('i2-pipefail-removed', 'pos_i2_pipefail.sh', 'set -o pipefail; ', '', 'pipeline stage'),
    ('i2-grep-stage', 'pos_i2_pipefail.sh', 'cat "$F" | cut', 'grep a "$F" | cut', 'no match'),
    ('i3-no-return', 'pos_i3_saved.sh', 'return 1; fi', 'echo failed >&2; fi', 'does not return or exit'),
    ('i3-status-clobbered', 'pos_i3_saved.sh', '  rc=$?\n', '  echo hi\n  rc=$?\n', 'statement after it'),
    ('i3-untested', 'pos_i3_saved.sh', 'if [ "$rc" != 0 ]; then', 'if [ -n "$rc" ]; then', 'does not test it'),
    ('i4-reassigned', 'pos_i4_snapshot.sh', 'while IFS= read', 'rows=$(cat "$F")\nwhile IFS= read', 'unchecked capture'),
    ('i4-unchecked-capture', 'pos_i4_snapshot.sh', 'rows=$(cat "$F") || exit 1', 'rows=$(cat "$F")', 'statement after it'),
    ('i4-other-variable', 'pos_i4_snapshot.sh', '<<< "$rows"', '<<< "$F"', 'not filled by one command substitution'),
    ('ck-fallback', 'pos_ck_command.sh', 'head -n 3 "$F" > /dev/null || exit 1', 'head -n 3 "$F" > /dev/null || true', 'falls back'),
    ('ck-test-negated', 'pos_ck_test.sh', '[ -e "$F" ] ||', '[ ! -e "$F" ] ||', 'metadata test'),
    ('ck-test-fallback', 'pos_ck_test.sh', '|| { echo "missing or unreadable: $F" >&2; exit 1; }', '|| echo missing', 'metadata test'),
    ('src-unchecked', 'pos_src_checked.sh', '. "$HERE/pos_src_checked.sh" || exit 1', '. "$HERE/pos_src_checked.sh"', 'last statement'),
    ('prop-helper-fallback', 'pos_prop.sh', 'x=$(rd "$F") || exit 1', 'x=$(rd "$F") || x=none', 'falls back'),
    ('prop-helper-not-last', 'pos_prop.sh', 'rd() { cat "$1"; }', 'rd() { cat "$1"; echo end; }', 'statement after it'),
    # reasons: an entry names a place, the contract checks what the place does
    ('v-write-after', 'pos_v_case.sh', 'esac\n', 'esac\necho done >> "$LOG"\n', '@V is for a read'),
    ('v-exit-after', 'pos_v_case.sh', 'esac\n', 'esac\nexit 0\n', '@V is for a read'),
    ('v-captured', 'pos_v_case.sh', 'tail -n "$n" "$B"', 'x=$(tail -n "$n" "$B")', 'matches no occurrence'),
    ('v-extra-function-control', 'pos_v_case.sh', 'case "$1" in', 'f() { :; }\ncase "$1" in', 'ok'),
    ('v-statement-edit', 'pos_v_case.sh', 'tail -n "$n" "$B"', 'tail -n "$n" "$B" "$B"', 'matches no occurrence'),
    ('v-and-chain', 'pos_v_case.sh', 'tail -n "$n" "$B" ;;', '[ -n "$n" ] && tail -n "$n" "$B" ;;', 'matches no occurrence'),
    ('v-duplicate-statement', 'pos_v_case.sh', '  *) echo usage >&2 ;;', '  tailx) n=${2:-20}; tail -n "$n" "$B" ;;\n  *) echo usage >&2 ;;', 'matches 2 occurrences'),
    ('v-pipefail-removed', 'pos_v_pipe.sh', 'set -o pipefail\n', '', 'no set -o pipefail'),
    ('v-pipeline-grep', 'pos_v_pipe.sh', 'sed -n "2,9p" "$B"', 'grep a "$B"', '@grep'),
    ('d-printed-to-file', 'pos_d_display.sh', 'echo "at $(date +%H:%M)"', 'echo "at $(date +%H:%M)" > "$LOG"', '@sends its output to a file'),
    ('d-held-in-variable', 'pos_d_display.sh', 'echo "at $(date +%H:%M)"', 'x="at $(date +%H:%M)"', '@echo or printf'),
    ('d-other-format', 'pos_d_display.sh', '$(date +%H:%M)', '$(date +%s)', '@allows only date'),
    ('k-not-a-tab', 'pos_k_tab.sh', "printf '\\t'", "printf '%s' x", '@literal tab'),
    ('h-other-file', 'pos_h_help.sh', '"$0"', '"$F"', '@H pipeline is not sed'),
    ('m-reads-a-file', 'pos_m_drain.sh', 'cat >/dev/null', 'cat "$F" >/dev/null', '@bare cat'),
    ('x-writes-state', 'pos_x_formatter.sh', '{ : >> "$1.flock"; }', '{ echo hi >> "$1.flock"; }', '@null-command probe'),
    ('x-not-terminal', 'pos_x_formatter.sh', '>&2; return 1', '>&2; echo more', '@followed by return or exit'),
    ('p-no-recheck', 'pos_p_recheck.sh', '  [ -e "$1" ] || { echo "$1 missing after create" >&2; return 1; }\n', '', '@later test'),
    ('p-recheck-other-operand', 'pos_p_recheck.sh', '[ -e "$1" ] || {', '[ -e "$2" ] || {', '@later test'),
    ('p-recheck-not-refusing', 'pos_p_recheck.sh', '[ -e "$1" ] || { echo "$1 missing after create" >&2; return 1; }', '[ -e "$1" ] || echo missing', '@recheck of the same operand'),
    ('c-wrong-loop', 'pos_c_continue.sh', 'for _ in 1 2; do', 'for _ in 1 2 3; do', 'nearest loop'),
    ('c-inner-loop-inserted', 'pos_c_continue.sh', 'x=$(cat "$F") || continue', 'while true; do x=$(cat "$F") || continue; break; done', 'nearest loop'),
    ('c-count', 'pos_c_continue.sh', '|| continue', '|| continue 2', 'falls back'),
    ('o-not-isolated', 'pos_o_opaque.sh', 'python3 -I -c', 'python3 -c', '@isolated'),
    ('o-text-changed', 'pos_o_opaque.sh', "print(1)", "print(2)", 'matches no occurrence'),
]


# Small trees (a file of helpers and a script that uses them): name -> (files, expected exit status, diagnostic)
LIB = '#!/usr/bin/env bash\ndie() { echo "$1" >&2; exit 1; }\n'
TREE_CASES = {
    'tree_helper_never_sourced': ({'bin/a.sh': LIB, 'bin/b.sh': 'F=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n'},
                                  1, 'falls back'),
    'tree_helper_sourced_after_use': ({'bin/a.sh': LIB, 'bin/b.sh': 'HERE=$(dirname "$0") || exit 1\nF=/dev/null\nx=$(cat "$F") || die "cannot read"\n'
                                       '. "$HERE/a.sh" || exit 1\necho "$x" > out\n'}, 1, 'falls back'),
    'tree_helper_sourced_control': ({'bin/a.sh': LIB, 'bin/b.sh': 'HERE=$(dirname "$0") || exit 1\n. "$HERE/a.sh" || exit 1\nF=${1:-}\n'
                                     'x=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}, 0, ''),
    'tree_helper_unchecked_source': ({'bin/a.sh': LIB, 'bin/b.sh': 'HERE=$(dirname "$0") || exit 1\n. "$HERE/a.sh"\nF=${1:-}\n'
                                      'x=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}, 1, 'falls back'),
    'tree_taint_in_sourced_file': ({'bin/a.sh': '#!/usr/bin/env bash\nexit() { :; }\n', 'bin/b.sh': 'HERE=$(dirname "$0") || exit 1\n. "$HERE/a.sh" || exit 1\n'
                                    'F=${1:-}\nx=$(cat "$F") || exit 1\necho "$x" > out\n'}, 1, 'hides or redefines'),
    'tree_source_same_name_other_folder': ({'bin/lib.sh': LIB, 'hooks/lib.sh': ':\n', 'bin/b.sh': 'HERE=$(dirname "$0") || exit 1\n. "$HERE/../hooks/lib.sh" || exit 1\n'
                                            'F=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}, 1, 'falls back'),
    'tree_source_computed_path': ({'bin/lib.sh': LIB, 'bin/b.sh': '. "$1/lib.sh" || exit 1\nF=${2:-}\nx=$(cat "$F") || exit 1\necho "$x" > out\n'}, 1, 'cannot resolve'),
    'tree_hooks_failing_read': ({'bin/a.sh': ':\n', 'hooks/h.sh': 'x=$(cat "$1")\necho "$x" > out\n'}, 1, 'files=2 occurrences=1'),
    'tree_missing_hooks_dir': ({'bin/a.sh': ':\n'}, 2, 'a whole class'),
    'tree_missing_bin_dir': ({'hooks/h.sh': ':\n'}, 2, 'a whole class'),
    # a sourced file has no $0 of its own: $0 there names whoever sourced it (here a hook, so the folder is hooks/ and not bin/)
    'tree_source_dollar0_in_sourced_file': ({'bin/die.sh': LIB, 'hooks/die.sh': ':\n',
                                             'bin/lib.sh': 'H2=$(dirname "$0") || exit 1\n. "$H2/die.sh" || exit 1\n',
                                             'hooks/h.sh': 'HERE=$(dirname "$0") || exit 1\n. "$HERE/../bin/lib.sh" || exit 1\n'
                                             'F=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}, 1, 'cannot resolve'),
    # a sourced file shares the sourcer's variables: lib.sh moves HERE before the second `.`
    'tree_source_sourced_file_reassigns_here': ({'bin/die.sh': LIB, 'hooks/die.sh': ':\n', 'bin/lib.sh': 'HERE=$HERE/../hooks\n',
                                                 'bin/b.sh': 'HERE=$(dirname "$0") || exit 1\n. "$HERE/lib.sh" || exit 1\n. "$HERE/die.sh" || exit 1\n'
                                                 'F=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}, 1, 'cannot resolve'),
    'tree_crossfile_unsourced_helper': ({'bin/a.sh': LIB + 'echo lib\n', 'bin/b.sh': '#!/usr/bin/env bash\nF=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n',
                                         'hooks/h.sh': '#!/usr/bin/env bash\necho hi\n'}, 1, 'falls back'),
}


# The file envelope (envelope on): a tree that is written in the forms the tree uses today shows no ENVELOPE row; each case below
# changes one thing. A diagnostic that starts with "!" must be ABSENT from the output (the controls).
CH = 'case $0 in */*) _d=${0%/*} ;; *) _d=. ;; esac\nHERE=$(cd -P "$_d" && pwd) || exit 1\n'
ENV_COMMON = '#!/usr/bin/env bash\nWR_ROOT=$(cd -P "${BASH_SOURCE[0]%/*}/.." && pwd)\ndie() { echo "$1" >&2; exit 1; }\n'
# the same library with the prelude in the order the refusal rules want (helper first, the one checked capture next)
ENV_COMMON_CHECKED = ('#!/usr/bin/env bash\ndie() { echo "$1" >&2; exit 1; }\n'
                      'WR_ROOT=$(cd -P "${BASH_SOURCE[0]%/*}/.." && pwd) || exit 1\n')
ENV_ENTRY = '#!/usr/bin/env bash\n' + CH + '. "$HERE/_common.sh" || exit 1\n'
ENV_HOOK = '#!/usr/bin/env bash\n' + CH + '. "$HERE/../bin/_common.sh" || exit 1\n'
ENV_BASE = {'bin/_common.sh': ENV_COMMON, 'bin/a.sh': ENV_ENTRY, 'hooks/h.sh': ENV_HOOK}


def env_tree(**changes):
    files = dict(ENV_BASE)
    files.update(changes)
    return files


TREE_CASES.update({
    'env_control_canonical_forms': (env_tree(), 1, '!ENVELOPE'),
    'env_out_extensionless_bin': (env_tree(**{'bin/warroom': ':\n'}), 1, 'not *.sh is never read'),
    'env_out_subfolder_bin': (env_tree(**{'bin/lib/x.sh': ':\n'}), 1, 'subfolder of bin/'),
    'env_out_bash_extension_hooks': (env_tree(**{'hooks/h2.bash': ':\n'}), 1, 'not *.sh is never read'),
    'env_out_symlink_in_bin': (env_tree(**{'bin/ln.sh': ('link', 'a.sh')}), 1, 'a symlink'),
    'env_out_dangling_symlink': (env_tree(**{'bin/ln.sh': ('link', 'nowhere.sh')}), 1, 'a symlink'),
    'env_out_library_in_hooks': (env_tree(**{'hooks/_x.sh': ':\n'}), 1, 'lives in bin/ only'),
    'env_entry_without_here': (env_tree(**{'bin/a.sh': '#!/usr/bin/env bash\n:\n'}), 1, 'sets HERE exactly once'),
    'env_entry_here_twice': (env_tree(**{'bin/a.sh': ENV_ENTRY + 'HERE=/x\n'}), 1, 'sets HERE exactly once'),
    'env_entry_here_other_form': (env_tree(**{'bin/a.sh': '#!/usr/bin/env bash\n' + CH.replace('cd -P', 'cd') + '. "$HERE/_common.sh" || exit 1\n'}),
                                  1, 'sets HERE exactly once'),
    'env_entry_here_no_case': (env_tree(**{'bin/a.sh': '#!/usr/bin/env bash\n_d=.\n_d=.\n:\nHERE=$(cd -P "$_d" && pwd) || exit 1\n. "$HERE/_common.sh" || exit 1\n'}),
                               1, 'sets HERE exactly once'),
    'env_entry_here_d_written_again': (env_tree(**{'bin/a.sh': ENV_ENTRY + '_d=/x\n'}), 1, 'sets HERE exactly once'),
    'env_entry_here_not_top_level': (env_tree(**{'bin/a.sh': '#!/usr/bin/env bash\ncase $0 in */*) _d=${0%/*} ;; *) _d=. ;; esac\nf() {\nHERE=$(cd -P "$_d" && pwd) || exit 1\n}\n'}),
                                     1, 'sets HERE exactly once'),
    'env_library_sets_here': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'HERE=/x\n'}), 1, 'never sets HERE'),
    'env_library_names_itself': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'x=$(dirname "$0")\n'}), 1, 'never names itself'),
    'env_library_names_itself_bash_source': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'x=${BASH_SOURCE[0]}\n'}), 1, 'never names itself'),
    'env_entry_sets_wr_root': (env_tree(**{'bin/a.sh': ENV_ENTRY + 'WR_ROOT=/x\n'}), 1, 'only the library sets WR_ROOT'),
    'env_source_keyword': (env_tree(**{'bin/a.sh': ENV_ENTRY + 'source "$HERE/_common.sh" || exit 1\n'}), 1, 'only the dot form'),
    'env_source_hook_form_in_bin': (env_tree(**{'bin/a.sh': '#!/usr/bin/env bash\n' + CH + '. "$HERE/../bin/_common.sh" || exit 1\n'}),
                                    1, 'one of three exact forms'),
    'env_source_not_a_library': (env_tree(**{'bin/b.sh': ':\n', 'bin/a.sh': ENV_ENTRY + '. "$HERE/b.sh" || exit 1\n'}), 1, 'one of three exact forms'),
    'env_source_missing_library': (env_tree(**{'bin/a.sh': ENV_ENTRY + '. "$HERE/_nope.sh" || exit 1\n'}), 1, 'not one of the scanned files'),
    'env_control_command_v_and_literal_trap': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'command -v python3 >/dev/null || exit 1\n'
                                                           "trap 'rm -f x' EXIT\n"}), 1, '!ENVELOPE E4'),
    'env_control_runner_and_sibling': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'wr_run() { "$@" 8>&- 9>&-; }\n',
                                                   'bin/b.sh': '#!/usr/bin/env bash\n' + CH + '"$HERE/a.sh" check\n'}), 1, '!ENVELOPE E4'),
    'env_control_trap_action_plain_calls': (env_tree(**{'bin/_common.sh': ENV_COMMON + "trap 'wr_drop \"$a\"; wr_drop \"$b\"' EXIT\n"}), 1, '!ENVELOPE E4'),
    'env_trap_action_exec_in_library': (env_tree(**{'bin/_common.sh': ENV_COMMON + "trap 'exec 2>\"$1\"' DEBUG\n"}), 1, 'a trap action holds only plain calls'),
    # a hook that sources an entry script is outside the envelope and so is everything in its own shell, but a separate entry
    # script is another process: its own rows stand (its two checked reads below, the folder capture and the file read, are still accepted)
    'env_hook_failure_leaves_other_processes': (env_tree(**{'bin/_common.sh': ENV_COMMON_CHECKED,
                                                            'bin/b.sh': ENV_ENTRY + 'y=1\n',
                                                            'hooks/h.sh': ENV_HOOK + '. "$HERE/../bin/b.sh" || exit 1\n',
                                                            'bin/a.sh': ENV_ENTRY + 'F=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}),
                                                1, 'ok=3 '),
    'env_control_high_descriptors': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'exec 9>>"$WR_ROOT/x.lock"\nexec 8>&-\nexec 9>&-\n'}), 1, '!ENVELOPE E3'),
    # a file outside the envelope shares its shell with every file it sources and every file that sources it: no row there stands
    'env_shared_shell_library_fails': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'exec 2>>"$WR_ROOT/log"\n',
                                                   'bin/a.sh': ENV_ENTRY + 'F=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}),
                                        1, 'shares a shell with it'),
    'env_shared_shell_entry_fails': (env_tree(**{'bin/a.sh': ENV_ENTRY + 'exec 2>>"$HERE/log"\n',
                                                 'bin/_common.sh': ENV_COMMON_CHECKED + 'F=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}),
                                     1, 'shares a shell with it'),
    'env_shared_shell_hook_library_fails': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'exec 2>&9\n',
                                                        'hooks/h.sh': ENV_HOOK + 'F=${1:-}\nx=$(cat "$F") || die "cannot read"\necho "$x" > out\n'}),
                                            1, 'shares a shell with it'),
    'env_runner_in_another_function': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'other() { "$@"; }\n'}), 1, 'computed command word'),
    # the runner's call sites: the target must be a named scanned script, judged where it is called
    'env_runcall_named_script': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'wr_run() { "$@" 8>&- 9>&-; }\n',
                                             'bin/b.sh': '#!/usr/bin/env bash\n' + CH + '. "$HERE/_common.sh" || exit 1\n',
                                             'bin/a.sh': ENV_ENTRY + 'wr_run "$HERE/b.sh" check || exit 1\n'}), 1, '!not a named scanned script'),
    'env_runcall_computed_target': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'wr_run() { "$@" 8>&- 9>&-; }\n',
                                                'bin/a.sh': ENV_ENTRY + 'wr_run "$1" check || exit 1\n'}), 1, 'not a named scanned script'),
    'env_runcall_no_target': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'wr_run() { "$@" 8>&- 9>&-; }\n',
                                          'bin/a.sh': ENV_ENTRY + 'wr_run || exit 1\n'}), 1, 'called with no target'),
    'env_runcall_target_not_scanned': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'wr_run() { "$@" 8>&- 9>&-; }\n',
                                                   'bin/a.sh': ENV_ENTRY + 'wr_run "$HERE/nope.sh" check || exit 1\n'}), 1, 'not a named scanned script'),
    'env_runcall_target_is_a_library': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'wr_run() { "$@" 8>&- 9>&-; }\n',
                                                    'bin/a.sh': ENV_ENTRY + 'wr_run "$HERE/_common.sh" check || exit 1\n'}), 1, 'not a named scanned script'),
    'env_runcall_runner_body_is_not_a_dispatch': (env_tree(**{'bin/_common.sh': ENV_COMMON + 'wr_run() { "$@" 8>&- 9>&-; }\n'}), 1, '!computed command word'),
    'env_sibling_not_scanned': (env_tree(**{'bin/b.sh': '#!/usr/bin/env bash\n' + CH + '"$HERE/nope.sh" check\n'}), 1, 'computed command word'),
    'env_source_computed_in_library': (env_tree(**{'bin/_common.sh': ENV_COMMON + '. "$1/_x.sh" || exit 1\n'}), 1, 'one of three exact forms'),
})


def run_tree(me, tmpd, name):
    """Write one tree case to a fresh folder and run the gate on it as its own process."""
    files, _, _ = TREE_CASES[name]
    files = dict(files)
    if not name.startswith('tree_missing_'):
        # the gate refuses a tree with no script in bin/ or in hooks/: give a case that has none a harmless one
        for d in ('bin', 'hooks'):
            if not any(f.startswith(d + '/') for f in files):
                files[d + '/noop.sh'] = ':\n'
    root = os.path.join(tmpd, name)
    for rel, text in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if isinstance(text, tuple):         # ('link', target): a symlink, possibly dangling
            os.symlink(text[1], path)
            continue
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(text)
    cmd = [sys.executable, '-I', me, '--enforce', '--root', root, '--allow', os.path.join(root, 'none')]
    env = dict(os.environ)
    if not name.startswith('env_'):
        # the statement-level trees test the judgments themselves; the env_ trees test the file envelope in front of them
        cmd.append('--no-envelope')
        env['READ_GATE_SELF_TEST'] = '1'
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, env=env)


# Mutants of this file: take a check out, and the fixture that pins it must stop failing. (name, old text, new text, fixture)
CODE_MUTANTS = [
    # rule 1: exit N (literal 1-255 by value, no redirection, no &), inert items in front
    ('code-r1-status-by-value', "re.fullmatch(r'[1-9][0-9]{0,2}', t) and int(t) <= 255", "re.fullmatch(r'[1-9][0-9]{0,2}', t)", 'neg_allow_exit_256.sh'),
    ('code-r1-no-redirection', 'if sm.assigns or sm.redirs or not sm.words:', 'if sm.assigns or not sm.words:', 'neg_allow_exit_bad_redir.sh'),
    ('code-r1-no-background', "if len(item.parts) != 1 or getattr(item, 'bg', False):\n                return False\n            return self._refusal(item.parts[0], bare_ok)",
     "if len(item.parts) != 1:\n                return False\n            return self._refusal(item.parts[0], bare_ok)", 'neg_proc_background_exit.sh'),
    ('code-r1-inert-prefix', 'if not items or not all(self.inert(x) for x in items[:-1]):\n            return False\n        # a bare', 'if not items:\n            return False\n        # a bare',
     'neg_allow_prefix_exits_zero.sh'),
    ('code-r1-group-redirection', "if getattr(item, 'redirs', None):\n                return False\n            return self._refusal_list(item.body, bare_ok)",
     'return self._refusal_list(item.body, bare_ok)', 'neg_allow_group_bad_redir.sh'),
    # rule 2: return N only inside a function
    ('code-r2-return-anywhere', 'return False        # outside a function', 'pass        # outside a function', 'neg_proc_toplevel_return.sh'),
    # rule 3: a call of a prelude helper with plain arguments
    ('code-r3-any-function', 'if name in self.helpers.get(self.fname_of(sm), ()):', 'if name in self.funcs:', 'neg_allow_die_param.sh'),
    ('code-r3-any-argument', 'return all(self.plain_word(w) for w in args)', 'return True', 'neg_allow_die_arg_expansion_err.sh'),
    # rule 4: the prelude (top-level, before the first other statement, defined once, no redirection, checked sources)
    ('code-r4-prelude-ends-at-use', 'if not self.plain_exit(rhs):\n                break', 'if not self.plain_exit(rhs):\n                pass',
     'neg_allow_use_before_definition_in_prelude_run.sh'),
    ('code-r4-prelude-folder-line-exact', "self.files[fname][0][it.start:it.end].strip() == self.CANON_HERE_CASE:\n                    continue", "True:\n                    continue",
     'neg_allow_helper_after_other_case.sh'),
    ('code-r4-prelude-ends-at-statement', "if name == 'trap' and args == ['', 'PIPE']:\n                    continue\n                break",
     "if name == 'trap' and args == ['', 'PIPE']:\n                    continue\n                continue", 'neg_allow_statement_before_definition.sh'),
    ('code-r4-top-level-only', 'for it in root.body.items:', "for it in [x for x in walk(root) if x.k == 'andor']:", 'neg_allow_def_in_uncalled_fn.sh'),
    ('code-r4-defined-once', 'if comp_defs == 1 and self.helper_body_ok(fn):', 'if comp_defs >= 1 and self.helper_body_ok(fn):', 'neg_allow_def_after_in_fn_body.sh'),
    ('code-r4-definition-redirection', "if c.body.k != 'group' or getattr(c.body, 'redirs', None):", "if c.body.k != 'group':", 'neg_allow_fn_def_redir.sh'),
    ('code-r4-helpers-per-file', 'for name, fn in visible(f, set()).items():\n                    # defined exactly once across the file and everything it sources, and a rule-1 body\n'
     '                    comp_defs = sum(1 for g in self.component(f)',
     'for name, fn in {k: v for g in self.files for k, v in pre[g][0].items()}.items():\n                    # defined exactly once across the file and everything it sources, and a rule-1 body\n'
     '                    comp_defs = sum(1 for g in self.files', 'tree:tree_helper_never_sourced'),
    ('code-r4-taint-reaches-sourcers', 'if bad:\n                for x in comp:\n                    self.taint[x] = bad[0]', 'if bad:\n                for x in []:\n                    self.taint[x] = bad[0]',
     'tree:tree_taint_in_sourced_file'),
    # no reason code can list a dispatch line
    ('code-f9-dispatch-never-listed', "if o.kind == 'DISPATCH':\n            return 'a dispatch line cannot be listed: nothing says what it runs, whatever the reason'\n        why = self.enclosing(o)", "why = self.enclosing(o)", 'neg_allow_dispatch_reason_D.sh', 'cannot be listed'),
    # discovery: both script folders must hold scripts, and a failing hook is in the inventory
    ('code-b5-hooks-class-scanned', "is reported by tree_out, never skipped.\"\"\"\n    out = []\n    for d in ('bin', 'hooks'):", "is reported by tree_out, never skipped.\"\"\"\n    out = []\n    for d in ('bin',):", 'tree:tree_hooks_failing_read', 'files=2'),
    ('code-fix7-missing-class-is-an-error', "if missing:\n            print('read-gate: no scripts found under %s/%s", "if False:\n            print('read-gate: no scripts found under %s/%s", 'tree:tree_missing_hooks_dir'),
    # an allow entry holds only where its statement sits: not inside a redirected group, not as a pipeline stage, not in the background
    ('code-b4-entry-bound-to-context', "why = self.enclosing(o)\n        if why:\n            return why", "why = None\n        if why:\n            return why", 'neg_allow_k_in_redirected_group.sh'),
    ('code-b4-entry-not-a-pipeline-stage', "if p.k == 'pipe' and len(p.cmds) > 1 and not (n.k == 'simple' and n is self_node):", "if False:", 'neg_allow_k_piped.sh', 'is a stage of a pipeline: its output'),
    # pipefail is proven at the read: nothing between the `set -o pipefail` and the pipeline may switch it off
    ('code-b3-pipefail-proven-at-read', "eff = self.opt_effect(it)", "eff = {True: 'on', False: 'off', None: None}[self.set_stmt(it)]", 'neg_pipefail_off_in_if.sh'),
    # the saved status is tested by a condition that is exactly one `[ ]` test
    ('code-b2-condition-is-one-test', "if len(cond.items) != 1:\n            return None         # the branch runs on the status of the LAST command of the condition\n        a = cond.items[0]\n        if a.k != 'andor' or a.ops:",
     "if not cond.items:\n            return None\n        a = cond.items[0]\n        if a.k != 'andor' or any(o != '||' for o in a.ops):", 'neg_saved_condition_extra_command.sh'),
    # a sourced file is the file at the resolved path, never the first file with the same name
    ('code-b1-source-by-basename', "return path if path in self.files else None", "return next((o for o in sorted(self.files) if posixpath.basename(o) == posixpath.basename(path)), None)",
     'tree:tree_source_same_name_other_folder'),
    ('code-b1-unresolved-source-taints', "why = '%s: a sourced file the gate cannot resolve to one of the scanned files' % where", "why = None", 'tree:tree_source_computed_path'),
    # rule 5: the path from the read to the refusal
    ('code-r5-no-background-in-chain', "if getattr(n, 'bg', False):\n                return False", 'if False:\n                return False', 'neg_proc_background_list.sh'),
    ('code-r5-no-pipe-stage-check', "if p.k == 'pipe' and len(p.cmds) > 1:\n                return False", 'if False:\n                return False', 'neg_proc_group_pipe_stage.sh'),
    ('code-r5-no-redirection-on-enclosing-if', "if p.k in ('group', 'if', 'while', 'for', 'case') and getattr(p, 'redirs', None):\n                return False",
     'if False:\n                return False', 'neg_allow_if_redirect_enclosing.sh'),
    ('code-r5-no-redirection-on-enclosing-group', "if p.k in ('group', 'if', 'while', 'for', 'case') and getattr(p, 'redirs', None):\n                return False",
     'if False:\n                return False', 'neg_allow_group_redirect_enclosing.sh'),
    # rule 6: anything else is not a refusal
    ('code-r6-unknown-command-refuses', '        return False\n\n    def inert(self, item):', '        return True\n\n    def inert(self, item):', 'neg_allow_unknown_command.sh'),
    # words a refusal relies on
    ('code-no-function-shadow-check', "if nd.k == 'func' and nd.name in TAINT_NAMES:", 'if False:', 'neg_shadow_exit_function.sh'),
    ('code-no-return-shadow-check', "if nd.k == 'func' and nd.name in TAINT_NAMES:", 'if False:', 'neg_shadow_return_function.sh'),
    ('code-no-unset-check', "if any(a is None for a in args) or '-f' in args or any(a in self.funcs or a in REFUSAL_WORDS for a in args if a):", 'if False:', 'neg_shadow_unset_function.sh'),
    ('code-no-exit-trap-check', "elif name == 'trap':\n                        why = self.check_trap(where, args)", "elif False:\n                        why = self.check_trap(where, args)",
     'neg_proc_exit_trap_rewrites.sh'),
    ('code-can-exit-exec-close-only', "if nm == 'exec' and len(d.words) == 1 and all(", "if nm == 'exec' and len(d.words) == 1 and True or all(", 'neg_allow_cleanup_helper_exec_opens_file.sh'),
    ('code-inert-helper-may-exit', "if nm in ('exit', 'kill', 'exec', 'command', 'builtin', 'eval', '$') or (nm in self.funcs and self.can_exit(nm, seen)):", 'if False:', 'neg_allow_cleanup_helper_exits_zero.sh'),
    ('code-no-alias-check', 'if name in SHADOW_CMDS:', 'if False:', 'neg_allow_alias.sh'),
    ('code-no-unknown-signal-check', "return '%s: trap on %s, which is not a signal name this gate knows' % (where, x)", 'continue', 'neg_allow_trap_unknown_signal_harmless.sh'),
    # round 4: what the first allowlist head missed
    ('code-r4-trap-every-signal', "if not sigs or action in ('', '-'):\n            return None", "if not sigs or action in ('', '-') or not any(x in TRAP_SPECIAL for x in sigs):\n            return None", 'neg_allow_trap_pipe_exit0.sh'),
    ('code-r4-subshell-call', "if p.k == 'subshell':\n                return 'bg'", "if False:\n                return 'bg'", 'neg_allow_subshell_call_of_refusing_function.sh'),
    ('code-r4-plain-word-dollar-text', "if isinstance(p, tuple) and p[0] == 'lit' and '$' in p[1]:", "if isinstance(p, tuple) and p[0] == 'lit' and False:", 'neg_allow_helper_arg_old_arith.sh'),
    ('code-r4-plain-word-dollar-text-quoted', "q[0] in ('lit', 'var') and not (q[0] == 'lit' and '$' in q[1])", "q[0] in ('lit', 'var')", 'neg_allow_helper_arg_old_arith_quoted.sh'),
    # the next two leave a dispatch line behind in their fixtures, so they are pinned by the diagnostic that must disappear
    ('code-r4-unwrap-command', "if name in ('command', 'builtin'):\n            words = words[1:]", "if False:\n            words = words[1:]", 'neg_allow_command_eval_redefines_exit.sh', 'hides or redefines'),
    ('code-r4-can-exit-wrappers', "'exec', 'command', 'builtin', 'eval', '$')", "'exec')", 'neg_allow_cleanup_helper_command_exit.sh', 'falls back'),
    # calls of script functions
    ('code-no-background-call-check', "if getattr(n, 'bg', False):\n                return 'bg'", "if False:\n                return 'bg'", 'neg_func_called_in_background.sh'),
    ('code-no-pipe-stage-call-check', "if kind == 'pipe' and name not in self.propagating:", 'if False:', 'neg_func_pipe_stage_unchecked.sh'),
    ('code-return-refusal-propagates', "return self.ok('REFUSE', func=self.returned_from(rhs))", "return self.ok('REFUSE')", 'neg_allow_return_in_function_called_unchecked.sh'),
    # the file envelope (E1 discovery, E2 sourcing and folder variables, E3 exec, E4 words that run anything)
    ('code-e1-subfolder', "elif rel != d:\n                    out.append", "elif False:\n                    out.append", 'tree:env_out_subfolder_bin', 'subfolder of bin/'),
    ('code-e1-not-sh', "elif not n.endswith('.sh'):\n                    out.append", "elif False:\n                    out.append", 'tree:env_out_extensionless_bin', 'not *.sh is never read'),
    ('code-e1-symlink', "if os.path.islink(fp):\n                    out.append", "if False:\n                    out.append", 'tree:env_out_symlink_in_bin', 'a symlink'),
    ('code-e1-library-folder', "if lib and folder != 'bin':", "if False:", 'tree:env_out_library_in_hooks', 'lives in bin/ only'),
    ('code-e2-library-sets-here', "if self.writes_var(root, 'HERE'):\n                    bad(f, None, 'E2', 'a sourced file never sets HERE')",
     "if False:\n                    bad(f, None, 'E2', 'a sourced file never sets HERE')", 'tree:env_library_sets_here', 'never sets HERE'),
    ('code-e2-library-names-itself', "if not inside:", "if False:", 'tree:env_library_names_itself', 'never names itself'),
    ('code-e2-entry-sets-wr-root', "if self.writes_var(root, 'WR_ROOT'):\n                    bad(f, None, 'E2', 'only the library sets WR_ROOT')",
     "if False:\n                    bad(f, None, 'E2', 'only the library sets WR_ROOT')", 'tree:env_entry_sets_wr_root', 'only the library sets WR_ROOT'),
    ('code-e2-entry-here-once', "if not ok_here:", "if False:", 'tree:env_entry_without_here', 'sets HERE exactly once'),
    ('code-e2-entry-here-count', "len(here_hits) == 1 and self.writes_var(root, 'HERE') == 1", "len(top) >= 1",
     'tree:env_entry_here_twice', 'sets HERE exactly once'),
    ('code-e2-entry-here-canonical', "== self.CANON_HERE\n", "!= ''\n", 'tree:env_entry_here_other_form', 'sets HERE exactly once'),
    ('code-e2-entry-here-case-line', "                           and src[items[at - 1].start:items[at - 1].end].strip() == self.CANON_HERE_CASE\n", "",
     'tree:env_entry_here_no_case', 'sets HERE exactly once'),
    ('code-e2-entry-here-d-once', "\n                           and self.writes_var(root, '_d') == 2)", ")", 'tree:env_entry_here_d_written_again', 'sets HERE exactly once'),
    ('code-e2-entry-here-top-level', "                           and at > 0\n", "", 'tree:env_entry_here_not_top_level', 'sets HERE exactly once'),
    ('code-e2-source-keyword', "if name == 'source':\n                    bad(", "if False:\n                    bad(", 'tree:env_source_keyword', 'only the dot form'),
    ('code-e2-source-entry-bin-form', "m = self.RE_SRC_ENTRY_BIN.match(text0)", "m = self.RE_SRC_ENTRY_BIN.match(text0) or self.RE_SRC_ENTRY_HOOK.match(text0)",
     'tree:env_source_hook_form_in_bin', 'one of three exact forms'),
    ('code-e2-source-entry-names-a-library', r"""RE_SRC_ENTRY_BIN = re.compile(r'^"\$HERE/(_[A-Za-z0-9_]+)\.sh"$')""",
     r"""RE_SRC_ENTRY_BIN = re.compile(r'^"\$HERE/([A-Za-z0-9_]+)\.sh"$')""", 'tree:env_source_not_a_library', 'one of three exact forms'),
    ('code-e2-source-library-form', r"""RE_SRC_LIB = re.compile(r'^"\$WR_ROOT/bin/(_[A-Za-z0-9_]+)\.sh"$')""",
     r"""RE_SRC_LIB = re.compile(r'^".*/(_[A-Za-z0-9_]+)\.sh"$')""", 'tree:env_source_computed_in_library', 'one of three exact forms'),
    ('code-e2-source-must-be-scanned', "elif 'bin/%s.sh' % m.group(1) not in self.files:", "elif False:", 'tree:env_source_missing_library', 'not one of the scanned files'),
    ('code-e3-exec-runs-command', "if len(nd.words) != 1:\n                        bad(f, nd, 'E3'", "if False:\n                        bad(f, nd, 'E3'",
     'neg_envelope_exec_runs_command.sh', 'never runs a command'),
    ('code-e3-exec-low-descriptors', "fd_ok = r.fd.isdigit() and int(r.fd) >= 3", "fd_ok = True", 'neg_envelope_exec_stdout.sh', 'never duplicates onto 1 or 2'),
    ('code-e3-exec-dup-onto-low', "dup_ok = r.op not in ('>&', '<&') or (", "dup_ok = True or (", 'neg_envelope_exec_dup_stderr.sh', 'never duplicates onto 1 or 2'),
    ('code-e4-eval', "elif name == 'eval':\n                    bad(", "elif False:\n                    bad(", 'neg_envelope_eval.sh', 'ENVELOPE E4: eval'),
    ('code-e4-command-builtin', "elif name in ('command', 'builtin') or cmd_name(nd) in ('command', 'builtin'):", "elif False:",
     'neg_envelope_command_wrapper.sh', 'command and builtin wrappers'),
    ('code-e4-trap-action-text', "if unwrapped(nd)[0] in ('exec', 'eval', 'source', '.', 'command', 'builtin', 'trap', '$')", "if False and unwrapped(nd)[0] in ('exec',",
     'neg_envelope_trap_action_exec_debug.sh', 'a trap action holds only plain calls'),
    ('code-e4-trap-computed', "if not args or any(a is None for a in args):", "if False:", 'neg_envelope_trap_computed.sh', 'literal action'),
    ('code-e4-computed-word', """if not (w0 == '"$@"' and fn is not None and (f, fn.name) in self.ENV_RUNNERS):""", "if False:",
     'neg_envelope_computed_word.sh', 'computed command word'),
    ('code-e4-runner-listed', "and (f, fn.name) in self.ENV_RUNNERS):", "):", 'tree:env_runner_in_another_function', 'computed command word'),
    ('code-runcall-target-named', "if tgt in self.files and tgt != o.file:", "if True:",
     'tree:env_runcall_target_not_scanned', 'not a named scanned script'),
    ('code-runcall-literal-form', "m = self.RE_RUN_TARGET.match(src[nd.words[1].start:nd.words[1].end])", "m = re.match(r'^.*$', src[nd.words[1].start:nd.words[1].end])",
     'tree:env_runcall_computed_target', 'not a named scanned script'),
    ('code-e4-sibling-scanned', "if sib and not lib and posixpath.join(folder, sib.group(1)) in self.files:", "if sib:", 'tree:env_sibling_not_scanned', 'computed command word'),
    # source identity and call-site context
    ('code-src-dollar0-names-the-sourcer', """if ('"$0"' in key or '"$_d"' in key) and (unknown or any(g != fname for g in tails.get(posixpath.basename(fname), ()))):""",
     "if False:", 'tree:tree_source_dollar0_in_sourced_file'),
    ('code-src-sourced-file-writes-the-variable', "if self.writes_var(self.files[g][2], var) != (1 if g == fname else 0):", "if False:",
     'tree:tree_source_sourced_file_reassigns_here'),
    ('code-ctx-call-with-redirect', "if any(self.file_out(r) for r in c.redirs):\n                return 'a call of %s sends its output to a file' % fn.name",
     "if False:\n                return 'a call of %s sends its output to a file' % fn.name", 'neg_allow_d_function_called_with_redirect.sh'),
    ('code-ctx-group-to-descriptor', "return t not in ('1', '2', '-')", "return False", 'neg_allow_d_group_to_file_descriptor.sh'),
    ('code-ctx-captured-value', "if capture and p.k in ('cs', 'ps', 'bt'):", "if False:", 'neg_allow_d_function_captured.sh', 'must be printed by echo or printf'),
    ('code-env-shared-shell', "for g in ((self.same_shell(f) | {f}) if f in self.files else {f}):", "for g in {f}:", 'tree:env_shared_shell_library_fails', 'shares a shell with it'),
    ('code-ctx-trap-action-call', "for t, c in self.trap_calls(fname, fn.name):", "for t, c in []:", 'neg_allow_d_trap_action_redirect.sh', 'in a trap action sends its output to a file'),
    ('code-env-voids-entries', "if o.kind == 'ENVELOPE' or getattr(o, 'envelope', False):", "if False:", 'neg_allow_d_after_exec_redirect.sh', 'outside the envelope'),
]


def self_test(here):
    fx_dir = os.path.join(here, FIX_DIR)
    fails = []
    passes = 0

    def check(label, cond, detail=''):
        nonlocal passes
        if cond:
            passes += 1
        else:
            fails.append('%s %s' % (label, detail))

    if not os.path.isdir(fx_dir):
        print('read-gate self-test: no fixture folder %s' % fx_dir)
        return 2
    names = sorted(f for f in os.listdir(fx_dir) if f.endswith('.sh'))
    if len(names) < 20:
        print('read-gate self-test: only %d fixtures found in %s (empty discovery is an error)' % (len(names), fx_dir))
        return 2
    texts = {}
    for f in names:
        with open(os.path.join(fx_dir, f), encoding='utf-8') as fh:
            texts[f] = fh.read()
    me = os.path.abspath(__file__)
    for f in names:
        text = texts[f]
        exp, allows, minocc = parse_header(text)
        if exp is None:
            fails.append('%s: no "# expect:" header' % f)
            continue
        # independent invocation: the gate runs as its own process and its exit status and output are asserted
        cmd = [sys.executable, '-I', me, '--enforce', '--fixture', os.path.join(fx_dir, f)]
        pr = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        out = pr.stdout
        if exp[0] == 'pass':
            check(f, pr.returncode == 0 and 'occurrences=' in out, 'expected pass, exit %d: %s' % (pr.returncode, out.strip().splitlines()[-1:] or ''))
            m = re.search(r'occurrences=(\d+)', out)
            check(f + ' (occurrences)', m is not None and int(m.group(1)) >= minocc, 'found %s occurrences, wanted %d' % (m.group(1) if m else '?', minocc))
        elif exp[0] == 'error':
            check(f, pr.returncode == 2, 'expected a tool error (exit 2), got exit %d: %s' % (pr.returncode, out.strip()[:200]))
            for key in exp[1]:
                check(f + ' (diagnostic %r)' % key, key.lower() in out.lower(), 'diagnostic missing from: %s' % out.strip()[:300])
        else:
            check(f, pr.returncode == 1, 'expected a refusal (exit 1), got exit %d: %s' % (pr.returncode, out.strip()[:200]))
            for key in exp[1]:
                check(f + ' (diagnostic %r)' % key, key.lower() in out.lower(), 'diagnostic missing from: %s' % out.strip()[:300])
    # mutants: pristine must pass, the change must apply exactly once, the mutant must fail with the named diagnostic
    for mid, base, old, new, want in MUTANTS:
        if base not in texts:
            fails.append('mutant %s: base fixture %s is missing' % (mid, base))
            continue
        text = texts[base]
        exp, allows, minocc = parse_header(text)
        try:
            entries = bind_entries(base, text, allows)
            an, d, i, a, u = run_text(base, text, entries)
        except ParseError as e:
            fails.append('mutant %s: base fixture does not parse: %s' % (mid, e))
            continue
        check('mutant %s (pristine passes)' % mid, exp is not None and exp[0] == 'pass' and not (d or i or a or u) and len(an.occs) >= 1,
              'pristine %s: %s' % (base, diagnostics(an, d, i, a, u)))
        if text.count(old) != 1:
            fails.append('mutant %s: the change was not applied (%d matches of %r in %s)' % (mid, text.count(old), old, base))
            continue
        mtext = text.replace(old, new)
        if want.startswith('@'):
            want = want[1:]
            try:
                entries = bind_entries(base, mtext, allows)
            except ParseError as e:
                fails.append('mutant %s: re-binding failed: %s' % (mid, e))
                continue
        try:
            an2, d2, i2, a2, u2 = run_text(base, mtext, entries)
        except ParseError as e:
            if want == 'unparsed':
                passes += 1
                continue
            fails.append('mutant %s: the mutated script does not parse (%s)' % (mid, e))
            continue
        diag = diagnostics(an2, d2, i2, a2, u2)
        if want == 'ok':
            check('mutant %s (still accepted: control)' % mid, not diag, 'unexpected: %s' % diag)
            continue
        check('mutant %s (fails)' % mid, bool(diag), 'the mutant was accepted')
        check('mutant %s (diagnostic %r)' % (mid, want), any(want.lower() in x.lower() for x in diag), 'got: %s' % diag[:3])
    # trees: helpers resolve per file, in order
    tdir = tempfile.mkdtemp(prefix='read-gate-tree-')
    try:
        for tname, (_, want_rc, want_diag) in sorted(TREE_CASES.items()):
            pr = run_tree(me, tdir, tname)
            check(tname, pr.returncode == want_rc, 'expected exit %d, got %d: %s' % (want_rc, pr.returncode, pr.stdout.strip()[:200]))
            if want_diag.startswith('!'):
                check(tname + ' (no %r in the output)' % want_diag[1:], want_diag[1:] not in pr.stdout,
                      'unexpected: %s' % pr.stdout.strip()[:300])
            elif want_diag:
                check(tname + ' (diagnostic %r)' % want_diag, want_diag in pr.stdout.lower() or want_diag in pr.stdout,
                      'diagnostic missing from: %s' % pr.stdout.strip()[:300])
    finally:
        shutil.rmtree(tdir, ignore_errors=True)
    # code mutants: the gate with one check removed must accept the fixture that pins that check
    with open(me, encoding='utf-8') as fh:
        src = fh.read()
    i0 = src.index('CODE_MUTANTS = [')
    src = src[:i0] + src[src.index('\n]\n', i0) + 3:]       # the table names the texts it changes: look past it
    tmpd = tempfile.mkdtemp(prefix='read-gate-mut-')
    try:
        for mid, old, new, fx, *gone in CODE_MUTANTS:
            if not fx.startswith('tree:') and fx not in texts or fx.startswith('tree:') and fx[5:] not in TREE_CASES:
                fails.append('code mutant %s: fixture %s is missing' % (mid, fx))
                continue
            if src.count(old) != 1:
                fails.append('code mutant %s: the change was not applied (%d matches)' % (mid, src.count(old)))
                continue
            mpath = os.path.join(tmpd, 'mutant.py')
            with open(mpath, 'w', encoding='utf-8') as fh:
                fh.write(src.replace(old, new))
            if fx.startswith('tree:'):
                pr = run_tree(mpath, tmpd, fx[5:])
            else:
                pr = subprocess.run([sys.executable, '-I', mpath, '--enforce', '--fixture', os.path.join(fx_dir, fx)],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
            if gone:
                check('code mutant %s (the diagnostic %r is gone for %s)' % (mid, gone[0], fx), gone[0] not in pr.stdout,
                      'the diagnostic is still there, so the check is not pinned: %s' % pr.stdout.strip()[:160])
                continue
            check('code mutant %s (the fixture %s is accepted)' % (mid, fx), pr.returncode == 0,
                  'exit %d (a fixture that still fails means the check is not pinned): %s' % (pr.returncode, pr.stdout.strip()[:160]))
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    # a gate that is broken must not look like a pass: parse failure and a missing file are tool errors (exit 2)
    pr = subprocess.run([sys.executable, '-I', me, '--enforce', '--fixture', os.path.join(fx_dir, 'does-not-exist.sh')],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    check('missing fixture file is a tool error', pr.returncode == 2, 'exit %d' % pr.returncode)
    pr = subprocess.run([sys.executable, '-I', me, '--enforce', '--root', os.path.join(fx_dir, 'no-such-root')],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    check('empty discovery is a tool error', pr.returncode == 2, 'exit %d' % pr.returncode)
    print('read-gate self-test: %d checks passed, %d failed (%d fixtures, %d trees, %d mutants, %d code mutants)' % (passes, len(fails), len(names), len(TREE_CASES), len(MUTANTS), len(CODE_MUTANTS)))
    for f in fails:
        print('  FAIL: %s' % f)
    return 1 if fails else 0


# ----------------------------------------------------------------------------------------------------------------------


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description='Which reads in bin/ and hooks/ can fail and still reach a state change?')
    ap.add_argument('--root', default=os.path.dirname(here), help='repository root (default: the folder above tests/)')
    ap.add_argument('--allow', default=os.path.join(here, 'read-gate.allow'))
    ap.add_argument('--enforce', action='store_true', help='exit 1 on any unlisted occurrence or bad allow entry')
    ap.add_argument('--verbose', action='store_true', help='print every occurrence')
    ap.add_argument('--tsv', help='write every occurrence to this file')
    ap.add_argument('--self-test', action='store_true')
    ap.add_argument('--propose', action='store_true', help='print allow-file lines that a reason contract accepts')
    ap.add_argument('--no-envelope', action='store_true', help=argparse.SUPPRESS)
    ap.add_argument('--fixture', help='analyze one fixture file; its "# allow:" header lines name the entries')
    a = ap.parse_args(argv)
    if a.no_envelope and os.environ.get('READ_GATE_SELF_TEST') != '1':
        print('read-gate: --no-envelope exists for the self-test only; the file envelope is part of the gate')
        return 2
    try:
        if a.self_test:
            return self_test(here)
        if a.fixture:
            with open(a.fixture, encoding='utf-8') as fh:
                text = fh.read()
            name = os.path.basename(a.fixture)
            exp, allows, minocc = parse_header(text)
            entries = bind_entries(name, text, allows)
            an, d, i, x, u = run_text(name, text, entries)
            bad = report(an, entries, d, i, x, verbose=True)
            return (1 if bad else 0) if a.enforce else 0
        files = tree_files(a.root)
        if not files:
            print('read-gate: no scripts found under %s/bin and %s/hooks' % (a.root, a.root))
            return 2
        missing = [d for d in ('bin', 'hooks') if not any(f.startswith(d + '/') for f in files)]
        if missing:
            print('read-gate: no scripts found under %s/%s: a whole class of scripts would go unread' % (a.root, ' or '.join(missing)))
            return 2
        an = analyze_files(a.root, files, envelope=not a.no_envelope)
        if a.propose:
            for ln in propose(an):
                print(ln)
            return 0
        entries = []
        if os.path.exists(a.allow):
            with open(a.allow, encoding='utf-8') as fh:
                entries = load_allow(fh.read(), a.allow)
        dead, invalid, ambiguous = apply_allow(an, entries)
        bad = report(an, entries, dead, invalid, ambiguous, verbose=a.verbose, tsv=a.tsv)
        if a.enforce:
            return 1 if bad else 0
        return 0
    except ParseError as e:
        print('read-gate: %s' % e)
        return 2
    except (OSError, UnicodeDecodeError) as e:
        print('read-gate: cannot read: %s' % e)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
