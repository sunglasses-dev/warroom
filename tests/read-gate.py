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
            if self.s.startswith('|&', self.i):
                self.err('|& is outside the supported subset')
            if self.i < self.n and self.s[self.i] == '|':
                self.i += 1
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
        if w in ('then', 'elif', 'else', 'fi', 'do', 'done', 'esac', 'in', 'function', 'select', 'coproc', 'time'):
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
REFUSE_VARS = set(['WR_CONFIG_EXIT'])
# words a refusal relies on: a script that redefines, removes, disables or aliases one of them is a tool error
REFUSAL_WORDS = set('exit return break continue exec trap set shopt unset command builtin eval source . : true false'.split())
SHADOW_CMDS = set('alias unalias enable'.split())
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
        self.refusing = set()
        self.propagating = set()
        self.occs = []

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
    def validate(self):
        for fname, (src, parser, root) in self.files.items():
            for nd in walk(root):
                if nd.k == 'func' and nd.name in REFUSAL_WORDS:
                    raise ParseError('%s line %d: a function named %s shadows the shell word a refusal relies on' % (
                        fname, parser.line(nd.start), nd.name))
                if nd.k != 'simple' or not nd.words:
                    continue
                name = cmd_name(nd)
                args = [word_lit(w) for w in nd.words[1:]]
                where = '%s line %d' % (fname, parser.line(nd.start))
                if name in SHADOW_CMDS:
                    raise ParseError('%s: %s can change what exit, return or a helper means' % (where, name))
                if name == 'unset':
                    if '-f' in args or any(a in self.funcs or a in REFUSAL_WORDS for a in args if a):
                        raise ParseError('%s: unset names a function or a refusal word' % where)
                if name == 'trap':
                    self.check_trap(where, args)

    def check_trap(self, where, args):
        if any(a is None for a in args):
            raise ParseError('%s: trap with a computed argument' % where)
        if not args or args[0] in ('-p', '-l'):
            return
        action, sigs = args[0], args[1:]
        if not sigs or action == '' or not any(x in ('EXIT', '0', 'ERR', 'DEBUG', 'RETURN') for x in sigs):
            return
        try:
            tree = Parser(action).parse_script()
        except ParseError as e:
            raise ParseError('%s: trap action does not parse (%s)' % (where, e))
        link(tree)
        for c in walk(tree):
            if c.k in ('cs', 'ps', 'bt', 'func'):
                raise ParseError('%s: trap action holds a substitution or a function' % where)
            if c.k == 'simple' and c.words:
                nm = cmd_name(c)
                if nm not in TRAP_SAFE:
                    raise ParseError('%s: an EXIT trap may rewrite the exit status; only %s are allowed in its action, not %s' % (
                        where, ' '.join(sorted(TRAP_SAFE)), nm))
                if self.can_exit(nm, set()):
                    raise ParseError('%s: trap helper %s can end the shell' % (where, nm))

    def can_exit(self, name, seen):
        """True when function `name`, or a function it calls, runs `exit` (a return only leaves the function)."""
        if name in seen:
            return False
        seen.add(name)
        for _, fn in self.funcs.get(name, []):
            for d in walk(fn):
                if d.k == 'simple' and d.words:
                    nm = cmd_name(d)
                    if nm in ('exit', 'kill') or (nm in self.funcs and self.can_exit(nm, seen)):
                        return True
        return False

    def proc_ok(self, node):
        """True when the refusal at `node` runs in the shell that did the read: not in the background, not a pipeline stage,
        not a subshell, not inside a substitution."""
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
            if p.k in ('func', 'script'):
                return True
            n = p
        return True

    # --- refusal ---
    def compute_refusing(self):
        self.refusing = set()
        changed = True
        while changed:
            changed = False
            for name, defs in self.funcs.items():
                if name in self.refusing or len(defs) != 1:
                    continue
                fn = defs[0][1]
                body = fn.body
                if body.k != 'group':
                    continue
                if any(n.k == 'simple' and cmd_name(n) == 'return' for n in walk(body)):
                    continue
                items = body.body.items
                if items and self.refusal_stmt(items[-1]):
                    self.refusing.add(name)
                    changed = True

    def refusal_stmt(self, item, bare_ok=False):
        """item: an andor. True when running it always ends the function or script with a nonzero status."""
        if item.k == 'andor':
            if len(item.parts) != 1 or getattr(item, 'bg', False):
                return False
            return self.refusal_stmt(item.parts[0], bare_ok)
        if item.k == 'pipe':
            if len(item.cmds) != 1 or item.neg:
                return False
            return self.refusal_stmt(item.cmds[0], bare_ok)
        if item.k == 'group':
            return self.refusal_list(item.body, bare_ok)
        if item.k == 'simple':
            if item.assigns or item.redirs and any(r.op in ('<', '<>') for r in item.redirs):
                return False
            name = cmd_name(item)
            args = [word_lit(w) for w in item.words[1:]]
            if name in ('exit', 'return'):
                if name == 'return':
                    a_ = item.parent
                    while a_ is not None and a_.k != 'func':
                        a_ = a_.parent
                    if a_ is None:
                        return False        # outside a function (or a sourced file) return fails and the script goes on
                if not args:
                    return bare_ok
                a = args[0]
                if a is not None and re.fullmatch(r'[1-9][0-9]{0,2}', a):
                    return True
                if name == 'exit' and len(item.words) == 2:
                    w = item.words[1]
                    if len(w.parts) == 1 and isinstance(w.parts[0], Node) and w.parts[0].k == 'dq':
                        q = w.parts[0].parts
                        if len(q) == 1 and q[0][0] == 'var' and q[0][1] in REFUSE_VARS:
                            return True
                return False
            if name in self.refusing:
                return True
        return False

    def refusal_list(self, lst, bare_ok=False):
        # a bare exit/return returns the status of the command before it: only a branch that is nothing else keeps the read's status
        return bool(lst.items) and self.refusal_stmt(lst.items[-1], bare_ok and len(lst.items) == 1)

    # --- pipefail ---
    def pipefail_active(self, pipe):
        n = pipe
        while n.parent is not None:
            p = n.parent
            if p.k == 'list':
                idx = p.items.index(n)
                state = False
                for it in p.items[:idx]:
                    st = self.set_stmt(it)
                    if st is not None:
                        state = st
                if state:
                    return True
                o = p.parent
                if o is not None and o.k in ('cs', 'ps', 'subshell', 'func', 'script'):
                    return False
            n = p
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
                            return self.ok('REFUSE')
                        if self.is_continue(rhs):
                            return self.bad('the failure only continues the loop', needs=('C',))
                        return self.bad('the failure falls back to a default or is ignored (|| x=.., || true, || echo ..)')
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
                                    return self.bad('the then branch does not refuse')
                                if not self.proc_ok(p):
                                    return self.bad('the refusal runs in another process (background job, pipeline stage, subshell)')
                                return self.ok('REFUSE')
                            if j < len(o.clauses) - 1:
                                return self.bad('an elif chain: the failure goes to the next condition')
                            if o.els is not None and self.refusal_list(o.els):
                                if not self.proc_ok(p):
                                    return self.bad('the refusal runs in another process (background job, pipeline stage, subshell)')
                                return self.ok('REFUSE')
                            return self.bad('the failure falls through the if (no else that refuses)')
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
                    return self.ok('I3')
                return self.bad('the failed-status branch reports an error but does not return or exit')
            if op in ('=', '-eq', '==') and lit == '0':
                body = it.clauses[0][1]
                if it.els is not None:
                    return self.bad('the success test has an else branch')
                if not self.ends_success(body):
                    return self.bad('the success branch can fall through into the failure path')
                if self.refuses_after(lst.items, k):
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
        if not cond.items:
            return None
        a = cond.items[0]
        if a.k != 'andor' or any(o != '||' for o in a.ops):
            return None
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
            if name == '$':
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
        self.compute_refusing()
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

    def check(self, o, e):
        fn = getattr(self, 'c_' + e.reason)
        return fn(o, e)

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

    def display_stmt(self, o):
        sm = self.outer_simple(o)
        # climb out of nested substitutions to the command that prints them
        while sm is not None:
            if sm.words and cmd_name(sm) in ('echo', 'printf') and not any(
                    r.op in ('>', '>>', '>|', '&>', '<', '<>') and word_lit(r.target) != '/dev/null' for r in sm.redirs):
                return True
            p = sm.parent
            while p is not None and p.k != 'cs':
                p = p.parent
            if p is None:
                break
            sm = self.outer_simple_of(p)
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
    out = []
    for d in ('bin', 'hooks'):
        p = os.path.join(root, d)
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if f.endswith('.sh'):
                    out.append(os.path.join(d, f))
    return out


def analyze_files(root, files):
    an = Analyzer()
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
    out.write('read-gate (report mode): files=%d occurrences=%d classes=%d unlisted=%d listed=%d ok=%d dead=%d invalid=%d ambiguous=%d\n'
              % (len(an.files), len(occs), len(kinds), len(unlisted), len(listed), len(ok), len(dead), len(invalid), len(ambiguous)))
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


def bind_entries(name, text, allows):
    """Build allow entries from a fixture's header against its own text (line numbers are the fixture's)."""
    an = Analyzer()
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
    an = Analyzer()
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
    ('i1-exit-trap-rewrites', 'pos_i1_exit.sh', 'F=${1:-}', "trap 'exit 0' EXIT; F=${1:-}", 'unparsed'),
    ('i1-exit-trap-cleanup-control', 'pos_i1_exit.sh', 'F=${1:-}', "trap 'rm -f x' EXIT; F=${1:-}", 'ok'),
    ('i1-exit-function-shadow', 'pos_i1_exit.sh', 'F=${1:-}', 'exit() { echo nope; }; F=${1:-}', 'unparsed'),
    ('i1-unset-function', 'pos_i1_exit.sh', 'F=${1:-}', 'unset -f die; F=${1:-}', 'unparsed'),
    ('i1-alias', 'pos_i1_exit.sh', 'F=${1:-}', 'alias exit=true; F=${1:-}', 'unparsed'),
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
    ('src-unchecked', 'pos_src_checked.sh', '. "$HERE/_common.sh" || exit 1', '. "$HERE/_common.sh"', 'last statement'),
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
    ('d-printed-to-file', 'pos_d_display.sh', 'echo "at $(date +%H:%M)"', 'echo "at $(date +%H:%M)" > "$LOG"', '@echo or printf'),
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


# Mutants of this file: take a check out, and the fixture that pins it must stop failing. (name, old text, new text, fixture)
CODE_MUTANTS = [
    ('code-no-background-in-branch', "len(item.parts) != 1 or getattr(item, 'bg', False)", 'len(item.parts) != 1', 'neg_proc_background_exit.sh'),
    ('code-no-background-in-chain', "if getattr(n, 'bg', False):", 'if False:', 'neg_proc_background_list.sh'),
    ('code-no-pipe-stage-check', "if p.k == 'pipe' and len(p.cmds) > 1:\n                return False", 'if False:\n                return False', 'neg_proc_group_pipe_stage.sh'),
    ('code-return-anywhere', 'return False        # outside a function', 'pass        # outside a function', 'neg_proc_toplevel_return.sh'),
    ('code-no-exit-trap-check', "if name == 'trap':", 'if False:', 'neg_proc_exit_trap_rewrites.sh'),
    ('code-no-function-shadow-check', "if nd.k == 'func' and nd.name in REFUSAL_WORDS:", 'if False:', 'neg_shadow_exit_function.sh'),
    ('code-no-return-shadow-check', "if nd.k == 'func' and nd.name in REFUSAL_WORDS:", 'if False:', 'neg_shadow_return_function.sh'),
    ('code-no-unset-check', "if '-f' in args or any(a in self.funcs or a in REFUSAL_WORDS for a in args if a):", 'if False:', 'neg_shadow_unset_function.sh'),
    ('code-redefined-helper', 'name in self.refusing or len(defs) != 1', 'name in self.refusing or len(defs) < 1', 'neg_shadow_helper_redefined.sh'),
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
    # code mutants: the gate with one check removed must accept the fixture that pins that check
    with open(me, encoding='utf-8') as fh:
        src = fh.read()
    i0 = src.index('CODE_MUTANTS = [')
    src = src[:i0] + src[src.index('\n]\n', i0) + 3:]       # the table names the texts it changes: look past it
    tmpd = tempfile.mkdtemp(prefix='read-gate-mut-')
    try:
        for mid, old, new, fx in CODE_MUTANTS:
            if fx not in texts:
                fails.append('code mutant %s: fixture %s is missing' % (mid, fx))
                continue
            if src.count(old) != 1:
                fails.append('code mutant %s: the change was not applied (%d matches)' % (mid, src.count(old)))
                continue
            want_rc = 2 if parse_header(texts[fx])[0][0] == 'error' else 1
            mpath = os.path.join(tmpd, 'mutant.py')
            with open(mpath, 'w', encoding='utf-8') as fh:
                fh.write(src.replace(old, new))
            pr = subprocess.run([sys.executable, '-I', mpath, '--enforce', '--fixture', os.path.join(fx_dir, fx)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
            check('code mutant %s (the fixture %s is accepted)' % (mid, fx), pr.returncode == 0,
                  'exit %d (a fixture that still fails means the check is not pinned): %s' % (pr.returncode, pr.stdout.strip()[:160]))
            _ = want_rc
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)
    # a gate that is broken must not look like a pass: parse failure and a missing file are tool errors (exit 2)
    pr = subprocess.run([sys.executable, '-I', me, '--enforce', '--fixture', os.path.join(fx_dir, 'does-not-exist.sh')],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    check('missing fixture file is a tool error', pr.returncode == 2, 'exit %d' % pr.returncode)
    pr = subprocess.run([sys.executable, '-I', me, '--enforce', '--root', os.path.join(fx_dir, 'no-such-root')],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    check('empty discovery is a tool error', pr.returncode == 2, 'exit %d' % pr.returncode)
    print('read-gate self-test: %d checks passed, %d failed (%d fixtures, %d mutants, %d code mutants)' % (passes, len(fails), len(names), len(MUTANTS), len(CODE_MUTANTS)))
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
    ap.add_argument('--fixture', help='analyze one fixture file; its "# allow:" header lines name the entries')
    a = ap.parse_args(argv)
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
        an = analyze_files(a.root, files)
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
