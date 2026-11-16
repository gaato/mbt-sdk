"""Qualify prelude/runtime constructors in emitted MoonBit, preserving wire names.

Domain constructors are qualified at their emission sites, where their owner is
known. This small lexer handles shared helpers/templates without touching quoted
spec data, comments, type names, or the constructor declarations themselves.
"""
import re
from io import StringIO


TOKEN = re.compile(r'//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|(?:@[A-Za-z_]\w*\.)?[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*|->|=>|\s+|.', re.S)
OWNERS = {
    **{name: 'Option' for name in ('Some', 'None')},
    **{name: 'Result' for name in ('Ok', 'Err')},
    **{name: '@json.Json' for name in ('Json', 'String', 'Number', 'Array', 'Object', 'True', 'False', 'Null')},
    **{name: name for name in ('Ref', 'Regex', 'ValidationError', 'PageDecodeError')},
    **{'@sdkjson.' + name: '@sdkjson.Presence' for name in ('Value', 'Absent', 'Null')},
    **{'@client.' + name: '@client.ResponseFailure' for name in ('Deserialization', 'UnexpectedStatus')},
    **{name: 'Failure' for name in ('Decode', 'Http', 'Transport', 'Validation')},
    **{name: '@http.Body' for name in ('Bytes', 'Stream')},
    **{name: 'PageKind' for name in ('Cursor', 'NextUrl')},
}
BARE = {'None', 'True', 'False', 'Null', 'NextUrl', '@sdkjson.Absent', '@sdkjson.Null'}


def qualify(source: str, owners=None, collisions=frozenset()) -> str:
    mapping = dict(OWNERS, **(owners or {}))
    # Keep one-token lookahead instead of a token/index dictionary for an entire
    # multi-megabyte SDK. Trivia is copied verbatim from the original source.
    tokens = (match for match in TOKEN.finditer(source)
              if not match[0].isspace() and not match[0].startswith('//'))
    current = next(tokens, None)
    output = StringIO()
    offset = 0
    before = ''
    declaration = False
    enum_depth = 0
    depth = 0
    while current is not None:
        following = next(tokens, None)
        token = current[0]
        after = following[0] if following is not None else ''
        replacement = token
        if token in ('enum', 'suberror'):
            declaration = True
        if token == '{':
            depth += 1
            if declaration:
                enum_depth = depth
                declaration = False
        if token == '}':
            if enum_depth == depth:
                enum_depth = 0
            depth -= 1
        skip = enum_depth or declaration or before in ('struct', 'suberror', 'fn', '.') or (
            before in (':', '->') and token not in collisions and after != '(')
        if not skip:
            owner = mapping.get(token)
            if owner in collisions:
                owner = '@builtin.' + owner
            if owner and (after == '(' or token in BARE):
                replacement = owner + '::' + token.rsplit('.', 1)[-1]
            elif token.split('::', 1)[0] in collisions:
                core = token.split('::', 1)[0]
                replacement = ('@json.' if core == 'Json' else '@builtin.') + token
            elif re.fullmatch(r'@[a-z_]\w*\.[A-Z]\w*', token) and after == '(':
                replacement = token + '::' + token.rsplit('.', 1)[-1]
        output.write(source[offset:current.start()])
        output.write(replacement)
        offset = current.end()
        before, current = token, following
    output.write(source[offset:])
    return output.getvalue()
