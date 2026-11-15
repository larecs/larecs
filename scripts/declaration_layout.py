"""Lay out declarations containing compiler-only syntax mojo format rejects."""

from dataclasses import dataclass, field
import re


_TOKENS = re.compile(r""""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[\[\](){},]|\s+|[^\[\](){},\s"']+|.""", re.S)
_PAIRS = {'[': ']', '(': ')', '{': '}'}
_HEADER = re.compile(r'^(?:async\s+)?(def|struct|trait|comptime)\s+\w+')


@dataclass
class _Group:
    opening: str = ''
    parts: list = field(default_factory=list)
    closing: str = ''


def _entries(parts):
    """Split at this group's commas, retaining existing trailing commas."""
    entry = []
    for part in parts:
        if part == ',':
            yield entry, True
            entry = []
        else:
            entry.append(part)
    if any(isinstance(part, _Group) or part.strip() for part in entry):
        yield entry, False


def _flat(parts):
    result = []
    for part in parts:
        if isinstance(part, str):
            result.append(part)
        else:
            items = list(_entries(part.parts))
            content = ', '.join(_flat(entry).strip() for entry, _ in items)
            if items and items[-1][1]:
                content += ','
            result.append(part.opening + content + part.closing)
    return ''.join(result)


def _parse(text):
    root = _Group()
    stack = [root]
    for token in _TOKENS.findall(text):
        if token in _PAIRS:
            group = _Group(token)
            stack[-1].parts.append(group)
            stack.append(group)
        elif token in _PAIRS.values():
            if len(stack) == 1 or _PAIRS[stack[-1].opening] != token:
                raise ValueError('Unbalanced declaration delimiters')
            stack.pop().closing = token
        else:
            stack[-1].parts.append(' ' if token.isspace() else token)
    if len(stack) != 1:
        raise ValueError('Unclosed declaration delimiter')
    return root


def format_declaration(text, width=80):
    """Break long declarations into parameter and argument lists.

    Nested lists break only when they do not fit. Strings, inference markers,
    existing commas, and compiler expressions retain their non-whitespace text.
    """
    root = _parse(text.strip())
    compact = _flat(root.parts).strip()
    if len(compact) <= width:
        return compact

    # Force the declaration's own lists onto separate lines, even when one
    # short list would fit after another list's closing delimiter.
    forced = set()
    prefix = ''
    for part in root.parts:
        if isinstance(part, str):
            prefix += part
            continue
        header = _HEADER.fullmatch(prefix.strip())
        if header and part.opening in ('[', '('):
            forced.add(id(part))
            if part.opening == '[':
                prefix = ''
                continue
        elif not prefix.strip() and forced and part.opening == '(':
            forced.add(id(part))
        break

    def render(parts, indent=0, prefix='', trailing=0):
        output = prefix
        for index, part in enumerate(parts):
            if isinstance(part, str):
                output += part
                continue
            flat = _flat([part])
            column = len(output.rsplit('\n', 1)[-1])
            items = list(_entries(part.parts))
            suffix = 0
            for following in parts[index + 1:]:
                if not isinstance(following, str):
                    suffix += len(following.opening)
                    break
                suffix += len(following)
            else:
                suffix += trailing
            if not items or (id(part) not in forced and column + len(flat) + suffix <= width):
                output += flat
                continue
            output += part.opening
            for entry, comma in items:
                # Whitespace around an entry comes from indentation, never
                # from the compiler's original spacing or an earlier layout.
                while entry and isinstance(entry[0], str) and entry[0].isspace():
                    entry = entry[1:]
                while entry and isinstance(entry[-1], str) and entry[-1].isspace():
                    entry = entry[:-1]
                output += '\n' + render(entry, indent + 4, ' ' * (indent + 4), int(comma))
                if comma:
                    output += ','
            output += '\n' + ' ' * indent + part.closing
        return output

    return render(root.parts).strip()
