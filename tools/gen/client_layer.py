"""Opt-in facade generation; the existing vocabulary emitter is deliberately unchanged."""
from __future__ import annotations

from dataclasses import replace
from collections import Counter
import copy
import json
from pathlib import Path
import re

from tools.gen.emit_moonbit import HEADER, emit, _operation, operation_locals
from tools.gen.qualify import qualify
from tools.gen.ir import IR, IRBuilder, HTTP_METHODS, Struct, header_api_key_names, json_response_media, media_type, pascal_case, snake_case, Note

TEMPLATES = Path(__file__).with_name('templates')

# Client methods share a namespace with operation wrappers, including private
# helpers and the Debug method, so reserve the complete facade surface together.
CLIENT_METHOD_NAMES = frozenset({
    'new', 'from_client', 'to_repr', 'authenticate', 'operation_config',
    'infer_operation', 'operation_base', 'prepare', 'call', 'send', 'stream',
    'stream_with_head', 'paginate',
})


def quote(value):
    return json.dumps(value, ensure_ascii=False)


def auth_choices(auth):
    return auth['schemes'] if auth['kind'] == 'alternatives' else [auth]


def scheme_auth(scheme):
    if scheme.get('type') == 'apiKey':
        return {'kind': scheme.get('in'), 'name': scheme.get('name')}
    if scheme.get('type') == 'oauth2':
        # Accept an already obtained access token; no OAuth flow is implemented.
        return {'kind': 'bearer'}
    if scheme.get('type') == 'http' and scheme.get('scheme', '').lower() in ('bearer', 'basic'):
        return {'kind': scheme['scheme'].lower()}
    raise ValueError(f'unsupported authentication scheme: {scheme!r}')


def security_requirements(security, label):
    """Return OR requirements, spelling an empty array as anonymous access."""
    if not isinstance(security, list):
        raise ValueError(f'{label}: security must be an array')
    return security or [{}]


def security_auth_choices(doc):
    """Return credential choices selected by OpenAPI security requirements.

    Requirement objects are OR alternatives; multiple schemes inside one object
    are an AND requirement, which the generated client deliberately cannot model.
    The boolean records whether the document supplied any security requirement,
    so scaffolding never infers policy from definitions alone.
    """
    schemes = doc.get('components', {}).get('securitySchemes', {})
    if not isinstance(schemes, dict) or not all(isinstance(value, dict) for value in schemes.values()):
        raise ValueError('securitySchemes must be an object of scheme definitions')
    choices = []
    saw_security = False

    def add(security, label):
        nonlocal saw_security
        saw_security = True
        for requirement in security_requirements(security, label):
            if not isinstance(requirement, dict):
                raise ValueError(f'{label}: security requirement must be an object')
            if len(requirement) > 1:
                raise ValueError(f'{label}: AND authentication is not supported')
            if not requirement:
                choice = {'kind': 'none'}
                if choice not in choices:
                    choices.append(choice)
            for name in requirement:
                definition = schemes.get(name)
                if not isinstance(definition, dict):
                    raise ValueError(f'{label}: unknown security scheme {name}')
                choice = scheme_auth(definition)
                if choice not in choices:
                    choices.append(choice)

    root_security = doc.get('security')
    root_present = 'security' in doc
    operations_found = False
    for path, item in doc.get('paths', {}).items():
        if not isinstance(item, dict):
            continue
        for method, operation in item.items():
            if method not in HTTP_METHODS or not isinstance(operation, dict):
                continue
            operations_found = True
            if 'security' in operation:
                add(operation['security'], f'{method.upper()} {path}')
            elif root_present:
                add(root_security, f'{method.upper()} {path}')
    if root_present and not operations_found:
        add(root_security, 'document')
    return choices, saw_security


def auth_constructor(auth, doc=None):
    if doc and 'x-moonbit-discovery' in doc:
        for name, scheme in doc.get('components', {}).get('securitySchemes', {}).items():
            if scheme_auth(scheme) == auth:
                return pascal_case(name)
    kind = auth['kind']
    return {'none': 'Anonymous', 'bearer': 'Bearer', 'basic': 'Basic'}.get(kind, pascal_case(str(auth.get('name', ''))))


def retry_source(config):
    if not config:
        return '@client.RetryPolicy::conservative()'
    def methods(value):
        if isinstance(value, list):
            return '@client.Methods::Listed([' + ', '.join('@http.Method::parse(' + quote(v) + ')' for v in value) + '])'
        return '@client.Methods::' + {'idempotent': 'Idempotent', 'any': 'Any', 'never': 'Never'}[value]
    def status_source(statuses):
        return ', '.join(f'@client.StatusMatch::Range({s[0]}, {s[1]})' if isinstance(s, list) else f'@client.StatusMatch::Code({s})' for s in statuses)
    base_statuses = config.get('statuses', [408, 409, 429, 500, 502, 503, 504])
    status_rules = [(base_statuses, config.get('methods', 'idempotent'))]
    if config.get('status_overrides'):
        # mttp selects the first rule matching a status, not the first matching
        # method. Union the method sets per code before emitting disjoint rules.
        def expand(statuses):
            return {code for s in statuses for code in (range(s[0], s[1] + 1) if isinstance(s, list) else [s])}
        def method_set(value):
            if value == 'any':
                return None
            if value == 'idempotent':
                return {'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS', 'TRACE'}
            return set() if value == 'never' else set(value)
        by_code = {code: method_set(config.get('methods', 'idempotent')) for code in expand(base_statuses)}
        for rule in config['status_overrides']:
            for code in expand(rule['statuses']):
                if code not in by_code:
                    by_code[code] = set()
                if by_code[code] is not None:
                    by_code[code] = by_code[code] | set(rule['methods'])
        groups = {}
        for code, allowed in sorted(by_code.items()):
            key = None if allowed is None else tuple(sorted(allowed))
            groups.setdefault(key, []).append(code)
        status_rules = [(codes, 'any' if allowed is None else list(allowed)) for allowed, codes in groups.items()]
    statuses = ', '.join('{ statuses: [' + status_source(codes) + '], methods: ' + methods(allowed) + ' }' for codes, allowed in status_rules)
    cap = config.get('retry_after_cap_ms', 60000)
    cap = 'NoCap' if cap == 'none' else f'{"BackoffAbove" if config.get("retry_after_cap", "stop") == "backoff" else "StopAbove"}({cap})'
    cap = '@client.RetryAfterCap::' + cap
    jitter = config.get('jitter', [800, 1200])
    jitter = f'Proportional(lo={jitter[0]}, hi={jitter[1]})' if isinstance(jitter, list) else {'none': 'NoJitter', 'full': 'Full'}[jitter]
    jitter = '@client.Jitter::' + jitter
    return f'''{{ rule: {{
      max_retries: {config.get('retries', 2)},
      statuses: [{statuses}],
      sent_failures: {methods(config.get('sent_failures', config.get('methods', 'idempotent')))},
      unsent_failures: {str(config.get('unprocessed_failures', True)).lower()},
      override_header: {'Option::Some(' + quote(config['override_header']) + ')' if config.get('override_header') else 'Option::None'},
      retry_after: {{ source: @client.RetryAfterSource::{ {'ignore': 'Ignore', 'header': 'Header', 'ms_then_header': 'MsThenHeader'}[config.get('retry_after', 'ms_then_header')]}, cap: {cap}, zero_means_backoff: {str(config.get('zero_means_backoff', False)).lower()} }},
      backoff: {{ base_ms: {config.get('backoff_base_ms', 500)}, max_ms: {config.get('backoff_max_ms', 30000)}, jitter: {jitter} }}
    }} }}'''


def operations(doc, ir):
    by_route = {(op.source_path or op.path, op.method): op for op in ir.operations}
    for path, item in doc.get('paths', {}).items():
        for method, raw in item.items():
            if method not in HTTP_METHODS or not isinstance(raw, dict):
                continue
            op = by_route.get((path, method.upper()))
            if op:
                yield op, raw, item


def client_names(doc, ir):
    """Shorten only the exact suffix FastAPI derives from path and method."""
    names, explicit = {}, set()
    full = {op.operation_id: op.moon_name for op in ir.operations}
    for op, raw, _ in operations(doc, ir):
        if 'x-moonbit-name' in raw:
            value = raw['x-moonbit-name']
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f'{op.operation_id}: x-moonbit-name must be nonempty')
            names[op.operation_id] = snake_case(value)
            explicit.add(op.operation_id)
        else:
            suffix = re.sub(r'[^A-Za-z0-9_]', '_', op.path) + '_' + op.method.lower()
            short = op.operation_id[:-len(suffix)] if op.operation_id.endswith(suffix) else ''
            names[op.operation_id] = snake_case(short) if short else op.moon_name
        if names[op.operation_id] in CLIENT_METHOD_NAMES:
            fallback = full[op.operation_id]
            names[op.operation_id] = fallback if fallback not in CLIENT_METHOD_NAMES else fallback + '_operation'
    while True:
        counts = Counter(names.values())
        collisions = {key for key, name in names.items() if counts[name] > 1 or name in CLIENT_METHOD_NAMES}
        if not collisions:
            return names
        changed = False
        for key in sorted(collisions):
            if key not in explicit and names[key] != full[key] and full[key] not in CLIENT_METHOD_NAMES:
                names[key] = full[key]
                changed = True
        if not changed:
            raise ValueError('client method name collision; use distinct x-moonbit-name overrides: ' + ', '.join(sorted(collisions)))


def error_status(status):
    return str(status) == 'default' or re.fullmatch(r'[45](?:[0-9]{2}|[Xx]{2})', str(status)) is not None


def error_priority(status):
    return 2 if str(status) == 'default' else 1 if str(status).upper().endswith('XX') else 0


def error_condition(status):
    if str(status) == 'default':
        return 'true'
    if str(status).upper().endswith('XX'):
        low = int(str(status)[0]) * 100
        return f'head.status >= {low} && head.status < {low + 100}'
    return f'head.status == {int(status)}'


def error_ir(doc, ir):
    """Lower error schemas independently, so no declarations leak into src/gen."""
    errors = copy.deepcopy(doc)
    errors['paths'] = {}
    cases = []
    schemas = {}
    for op, raw, _ in operations(doc, ir):
        for status, response in sorted(raw.get('responses', {}).items(), key=lambda item: error_priority(item[0])):
            if not error_status(status):
                continue
            schema = next((media.get('schema') for kind, media in response.get('content', {}).items()
                           if json_response_media(kind) and isinstance(media.get('schema'), dict)), None)
            if schema is None:
                continue
            identity = json.dumps(schema, sort_keys=True)
            name = schemas.get(identity)
            if name is None:
                name = 'error_' + op.moon_name + '_' + str(status).lower()
                schemas[identity] = name
                errors['paths']['/' + name] = {'get': {
                    'operationId': name, 'x-moonbit-include': True,
                    'responses': {'200': {'content': {'application/json': {'schema': schema}}}},
                }}
            cases.append((op.operation_id, str(status), name))
    lowered = IRBuilder(errors, ir.package, derive_operation_ids=True).build()
    return lowered, cases


def request_parts(op, raw, prefix, auth_headers):
    """Reuse the vocabulary's signature construction, including multipart details."""
    # Dummy strings satisfy legacy builders' required credential parameters; the
    # facade removes them before attaching the selected construction-time auth.
    dropped = [p for p in op.parameters if p.location == 'header' and p.json_name.lower() in auth_headers]
    filtered = replace(op, parameters=tuple(p for p in op.parameters if p not in dropped))
    source = _operation(filtered)
    signature = source[source.index('pub fn '):source.index(' -> @http.Request')]
    params = signature[signature.index('(') + 1:signature.rindex(')')]
    for parameter in filtered.parameters:
        if parameter.required and parameter.location in ('path', 'query'):
            params = params.replace(parameter.moon_name + ' :', parameter.moon_name + '~ :')
    # Use the IR kind, not spelling: a legal schema called Json or Result is
    # a domain type even though a primitive/prelude type shares that spelling.
    if prefix:
        formals = [(p.moon_name, p.type) for p in filtered.parameters]
        if op.request_type:
            formals.append((operation_locals(filtered)['body'], op.request_type))
        formals.extend((field.moon_name, field.type) for field in op.multipart_fields if field.type)
        for name, ref in formals:
            for suffix in ('', '?', '~'):
                params = params.replace(name + suffix + ' : ' + ref.moon_type(),
                                        name + suffix + ' : ' + qualified_ref(ref, prefix))
    positional = [p.moon_name if p not in dropped else '""' for p in op.parameters if p.required]
    if op.request_type:
        positional.append(operation_locals(filtered)['body'])
    for field in op.multipart_fields:
        names = multipart_names(field)
        if field.required:
            positional.extend(names)
    if op.multipart_fields:
        positional.append(operation_locals(filtered)['boundary'])
    positional.extend(p.moon_name + '?' for p in op.parameters if not p.required and p not in dropped)
    for field in op.multipart_fields:
        if not field.required:
            positional.extend(name + '?' for name in multipart_names(field))
    request = f'{prefix}{op.moon_name}_request({", ".join(positional)})'
    content = raw.get('requestBody', {}).get('content', {})
    if content and not op.request_type and not op.multipart_fields:
        params += (', ' if params else '') + 'body : Bytes, content_type~ : String'
        request += '.body_bytes(body, content_type~)'
    return params, request


def success_media(raw):
    return [media_type(kind) for status, response in raw.get('responses', {}).items()
            if str(status).startswith('2') for kind in response.get('content', {})]


def wrapper(op, raw, prefix, client, auth_headers, name):
    params, request = request_parts(op, raw, prefix, auth_headers)
    request = validated_request(op, request, prefix)
    stream_kind = raw.get('x-moonbit-stream')
    if stream_kind is not None and stream_kind != 'sse':
        raise ValueError(f'{op.operation_id}: unsupported x-moonbit-stream {stream_kind!r}')
    if stream_kind == 'sse':
        if op.response_type is None:
            raise ValueError(f'{op.operation_id}: SSE operation needs a JSON response schema')
        result = qualified_ref(op.response_type, prefix)
        params = 'self : ' + client + (', ' + params if params else '')
        params += f', receive : async ({result}) -> Unit, stop? : ({result}) -> Bool'
        return f'''///|
/// Streams {op.operation_id} as typed SSE JSON events; alt=sse is always set.
pub async fn {client}::{name}({params}) -> Result[Unit, Failure] {{
  let request = {request}.query("alt", "sse")
  let decoded : Ref[{result}?] = Ref(None)
  let decode_error : Ref[@client.ResponseFailure?] = Ref(None)
  let stream_result = self.stream_with_head(
    request,
    _event => match decoded.val {{
      Some(value) => {{ decoded.val = None; receive(value) }}
      None => ()
    }},
    stop=(head, event) => match {prefix}{op.moon_name}_decode(
      head,
      @utf8.encode(event.data),
    ) {{
      Err(error) => {{ decode_error.val = Some(error); true }}
      Ok(value) => match stop {{
        Some(predicate) if predicate(value) => true
        _ => {{ decoded.val = Some(value); false }}
      }}
    }},
    operation={quote(op.operation_id)},
  )
  match decode_error.val {{
    Some(error) => Err(Decode(error))
    None => stream_result
  }}
}}
'''
    if op.response_type:
        result = qualified_ref(op.response_type, prefix)
        expression = f'self.call(request, {prefix}{op.moon_name}_decode, operation={quote(op.operation_id)})'
    elif not success_media(raw):
        result = 'Unit'
        expression = f'''match self.send(request, operation={quote(op.operation_id)}) {{
          Ok(_) => Ok(())
          Err(error) => Err(error)
        }}'''
    elif any(media.startswith('text/') and media != 'text/event-stream' for media in success_media(raw)):
        result = 'String'
        expression = f'''match self.send(request, operation={quote(op.operation_id)}) {{
          Err(error) => Err(error)
          Ok(reply) => match decode_text({{ status: reply.status, headers: reply.headers }}, reply.body) {{
            Ok(value) => Ok(value)
            Err(error) => Err(Decode(error))
          }}
        }}'''
    else:
        result = '@client.Reply[Bytes]'
        expression = f'self.send(request, operation={quote(op.operation_id)})'
    params = 'self : ' + client + (', ' + params if params else '')
    doc = f'///|\n/// Calls {op.operation_id}.\n'
    text = doc + f'pub async fn {client}::{name}({params}) -> Result[{result}, Failure] {{\n  let request = {request}\n  {expression}\n}}\n'
    sse = any(media_type(k) == 'text/event-stream' for status, r in raw.get('responses', {}).items()
              if str(status).startswith('2') for k in r.get('content', {}))
    if sse:
        # A separate stream method also serves operations with JSON alternatives.
        stream_params = params + ', receive : async (@sse.SseEvent) -> Unit, stop? : (@sse.SseEvent) -> Bool'
        stream_name = name + '_stream' if op.response_type else name
        stream = f'''///|
/// Streams {op.operation_id}. Use stop to finish early and close the body.
pub async fn {client}::{stream_name}({stream_params}) -> Result[Unit, Failure] {{
  let request = {request}
  self.stream(request, receive, stop?, operation={quote(op.operation_id)})
}}
'''
        text = text + '\n' + stream if op.response_type else stream
    return text


def multipart_names(field):
    suffixes = {'file': ['', '_filename', '_content_type'], 'file_array': ['', '_filenames', '_content_types']}
    return [field.moon_name + s for s in suffixes.get(field.kind, [''])]


def validated_request(op, request, prefix, *, paginator=False):
    if not any(parameter.resource_name for parameter in op.parameters):
        return request
    failure = f'Validation(operation={quote(op.operation_id)}, parameter~, message~)'
    result = f'@client.Paginator::new(() => Err({failure}))' if paginator else f'Err({failure})'
    other = '\n      error => raise error' if op.multipart_fields else ''
    return f'''(try {{ {request} }} catch {{
      {prefix}ValidationError(parameter~, message~) => return {result}{other}
    }})'''


def qualified_ref(ref, prefix):
    if ref.kind == 'named':
        return prefix + ref.name
    if ref.kind == 'array':
        return 'Array[' + qualified_ref(ref.item, prefix) + ']'
    if ref.kind == 'map':
        return 'Map[String, ' + qualified_ref(ref.item, prefix) + ']'
    if ref.kind == 'optional':
        return qualified_ref(ref.item, prefix) + '?'
    return ref.moon_type()


def emit_client(doc, ir, sdk, vocabulary_files=None):
    client = pascal_case(sdk['name'])
    prefix = '' if sdk['out'] == sdk['dir'] + '/src' else '@gen.'
    names = client_names(doc, ir)
    choices = auth_choices(sdk['auth'])
    auth_headers = {'authorization'} | {a['name'].lower() for a in choices if a['kind'] == 'header'}
    variants = ['  Anonymous']
    for a in choices:
        ctor = auth_constructor(a, doc)
        if a['kind'] != 'none':
            variants.append('  ' + ctor + ('(String, String)' if a['kind'] == 'basic' else '(String)'))
    if len(set(v.split('(')[0] for v in variants)) != len(variants):
        raise ValueError('authentication constructor name collision')
    auth = '///|\n/// Credentials selected at construction; Debug deliberately redacts values.\npub(all) enum Auth {\n' + '\n'.join(variants) + '\n}\n'
    auth += '''///|
pub extend Auth with @debug.Debug::{to_repr}
///|
pub impl @debug.Debug for Auth with fn to_repr(_) {
  @debug.Repr::literal("<credentials redacted>")
}
'''
    apply = ['match self.auth {', 'Auth::Anonymous => request']
    for a in choices:
        ctor = auth_constructor(a, doc)
        if a['kind'] == 'none':
            continue
        args = 'username, password' if a['kind'] == 'basic' else 'value'
        expression = {
                      'bearer': '''{
  @http.Headers::of([("authorization", value)]).validate()
  request.credential("authorization", "Bearer " + value)
}''',
                      'basic': 'request.basic(username, password)',
                      'header': f'request.credential({quote(a.get("name", ""))}, value)',
                      'query': f'request.query({quote(a.get("name", ""))}, value)'}[a['kind']]
        apply.append(f'Auth::{ctor}({args}) => {expression}')
    apply.append('}')
    credential_headers = sorted((auth_headers | header_api_key_names(doc)) - {'authorization'})
    auth_effect = ' raise @http.TransportError' if any(a['kind'] == 'bearer' for a in choices) else ''
    auth_code = auth + '\n///|\nfn ' + client + '::authenticate(self : ' + client + ', request : @http.Request) -> @http.Request' + auth_effect + ' {\n' + '\n'.join(apply) + '\n}\n'
    metadata = []
    routes = []
    error_types, error_cases = error_ir(doc, ir)
    error_names = {op.operation_id: op.response_type.moon_type() for op in error_types.operations}
    error_variants = {}
    error_decode = []
    for operation, status, name in error_cases:
        schema_type = error_names[name]
        variant = 'RawJson' if schema_type == 'Json' else pascal_case(schema_type)
        if variant in error_variants and error_variants[variant] != schema_type:
            raise ValueError(f'error schema variant name collision: {variant}')
        error_variants[variant] = schema_type
        condition = error_condition(status)
        error_decode.append(f'''if operation == {quote(operation)} && {condition} {{
          let value : {error_names[name]} = @json.from_json(json)
          return Some(ErrorBody::{variant}(value))
        }}''')
    for op, raw, item in operations(doc, ir):
        security = raw.get('security', doc.get('security'))
        allowed = []
        if security is None:
            # Missing security in vendor descriptions uses the pinned auth.
            allowed = choices
        else:
            for requirement in security_requirements(security, op.operation_id):
                if len(requirement) > 1:
                    raise ValueError(f'{op.operation_id}: AND authentication is not supported')
                if not requirement:
                    a = {'kind': 'none'}
                    if a not in choices:
                        raise ValueError(f'{op.operation_id}: anonymous access is absent from the pinned auth')
                    allowed.append(a)
                for name in requirement:
                    definition = doc.get('components', {}).get('securitySchemes', {}).get(name)
                    if definition is None:
                        definition = doc.get('x-moonbit-auth', {}).get(name)
                    if not isinstance(definition, dict):
                        raise ValueError(f'{op.operation_id}: unknown security scheme {name}')
                    a = scheme_auth(definition)
                    if a not in choices:
                        raise ValueError(f'{op.operation_id}: scheme {name} is absent from the pinned auth')
                    allowed.append(a)
        patterns = ['Auth::' + auth_constructor(a, doc) + ('(_, _)' if a['kind'] == 'basic' else '(_)' if a['kind'] != 'none' else '') for a in allowed]
        # Anonymous-only access means credentials are never attached.  Keep the
        # compact historical representation while retaining Anonymous in the pin.
        auth_bool = 'false' if not patterns or all(a['kind'] == 'none' for a in allowed) else 'match self.auth { ' + ' | '.join(dict.fromkeys(patterns)) + ' => true; _ => false }'
        servers = raw.get('servers', item.get('servers', []))
        server = servers[0]['url'] if servers else ''
        if '{' in server:
            raise ValueError(f'{op.operation_id}: server variables require an overlay')
        metadata.append(f'{quote(op.operation_id)} => ({auth_bool}, {quote(server)})')
        if any(parameter.resource_name for parameter in op.parameters):
            parameters = {parameter.json_name: parameter for parameter in op.parameters}
            parts = []
            for part in re.split(r'(\{[^}]+\})', op.path):
                if part.startswith('{') and part.endswith('}'):
                    parameter = parameters[part[1:-1]]
                    pattern = parameter.pattern or ('.+' if parameter.path_segments else '[^/]+')
                    parts.append('(?:' + pattern.removeprefix('^').removesuffix('$') + ')')
                else:
                    parts.append(re.escape(part))
            condition = f'resource_route_matches(request.url, {quote("^" + "".join(parts) + "$")}, self.operation_base({quote(server)}))'
        else:
            condition = f'route_matches(request.url, {quote(op.path)}, self.operation_base({quote(server)}))'
        routes.append(f'if request.meth == @http.Method::parse({quote(op.method)}) && {condition} {{ return {quote(op.operation_id)} }}')
    metadata_code = f'''///|
fn {client}::operation_config(self : {client}, operation : String) -> (Bool, String) {{
  ignore(self)
  match operation {{
    {'\n'.join(metadata)}
    _ => (true, "")
  }}
}}
///|
fn {client}::infer_operation(self : {client}, request : @http.Request) -> String {{
  {'\n'.join(routes)}
  ""
}}
'''
    if any(parameter.resource_name for op in ir.operations for parameter in op.parameters):
        metadata_code += '''///|
// Match the complete canonical name, including its collection, so operations
// sharing /{name} retain distinct error/auth/observer metadata on generic calls.
fn resource_route_matches(url : String, pattern : String, base_url : String) -> Bool {
  try {
    let parsed = @http.Url::parse(url)
    let path = if parsed.is_absolute() {
      let base = @http.Url::parse(base_url)
      if !parsed.same_origin(base) { return false }
      let prefix = base.path.trim_end(chars="/").to_owned()
      if parsed.path == prefix { "/" } else if parsed.path.has_prefix(prefix + "/") {
        parsed.path[prefix.length():].to_owned()
      } else { return false }
    } else { parsed.path }
    Regex(pattern).execute(path) is Some(_)
  } catch { _ => false }
}
'''
    failure = '''///|
/// HTTP failure with exact response bytes and an optional typed interpretation.
#derive(@debug.Debug)
pub(all) struct HttpFailure {
  operation : String
  head : @http.ResponseHead
  body : Bytes
  typed : ErrorBody?
}
///|
pub extend HttpFailure with @debug.Debug::{to_repr}
///|
/// Transport failures retain their kind and phase. Unknown callback errors propagate.
#derive(@debug.Debug)
#non_exhaustive
pub(all) enum Failure {
  Http(HttpFailure)
  Transport(@http.TransportError)
  Decode(@client.ResponseFailure)
  Validation(operation~ : String, parameter~ : String, message~ : String)
}
///|
pub extend Failure with @debug.Debug::{to_repr}
///|
#derive(@debug.Debug)
#non_exhaustive
pub(all) enum ErrorBody {
''' + ('\n'.join(f'  {variant}({typ})' for variant, typ in error_variants.items()) if error_variants else '  RawJson(Json)') + '\n}\n///|\npub extend ErrorBody with @debug.Debug::{to_repr}\n'
    if error_cases:
        # An explicit status outranks a range, which outranks default, even when
        # the spec lists the broader schema first.
        error_decode = [code for (_, status, _), code in sorted(zip(error_cases, error_decode), key=lambda pair: error_priority(pair[0][1]))]
        typed = '\n'.join(error_decode) + '\nNone'
        typed = 'let json = @json.parse(@utf8.decode(body))\n' + typed
    else:
        typed = 'ignore(operation)\nignore(head)\nSome(ErrorBody::RawJson(@json.parse(@utf8.decode(body))))'
    failure += f'''///|
fn typed_error(operation : String, head : @http.ResponseHead, body : Bytes) -> ErrorBody? {{
  try {{ {typed} }} catch {{ _ => None }}
}}
'''
    # error schemas get the same proven JSON codecs, but stay in the facade.
    error_code = emit(IR(ir.package, error_types.declarations, ()))['types.mbt'][len(HEADER):]
    runtime = (TEMPLATES / 'client.mbt').read_text().replace('__CLIENT__', client).replace('__BASE_URL__', quote(sdk['base_url'])).replace('__PROVIDER__', quote(sdk['name'])).replace('= Anonymous', '= Auth::Anonymous')
    if ir.operations and all(any(p.resource_name for p in op.parameters) for op in ir.operations):
        # Resource-only clients use the pattern matcher; keep strict builds free
        # of an unused legacy template matcher without changing existing SDKs.
        start = runtime.index('///|\nfn route_matches(')
        end = runtime.index('///|\nfn ' + client + '::operation_base', start)
        runtime = runtime[:start] + runtime[end:]
    if doc.get('x-moonbit-nonraising-decoders') is True:
        # Opt-in for new modules: the pinned compiler cannot link an async generic
        # call with a raise? decoder instantiated by a typed external wrapper.
        # Existing modules retain their callback contract and byte-identical output.
        runtime = runtime.replace('Result[T, @client.ResponseFailure] raise?', 'Result[T, @client.ResponseFailure]')
    runtime = runtime.replace('__CREDENTIAL_HEADERS__', '\n'.join('credential_headers.push(' + quote(n) + ')' for n in credential_headers))
    runtime = runtime.replace('__REQUEST_CREDENTIAL_HEADERS__', ', '.join(quote(n) for n in ['authorization', *credential_headers]))
    runtime = runtime.replace('__STRIP_HEADERS__', ''.join(f'.remove({quote(h)})' for h in sorted(auth_headers)))
    runtime = runtime.replace('__IDEMPOTENCY__', '\n'.join(f'if request.headers.get({quote(h)}) is Some(value) && value != "" {{ request = request.attribute(@http.replay_safe, true) }}' for h in sdk.get('idempotency_headers', doc.get('x-moonbit-idempotency-headers', []))))
    runtime = runtime.replace('__QUERY_WARNING__', 'Query credentials appear in redirect history and observer URLs.' if any(a['kind'] == 'query' for a in choices) else 'Credentials are redacted from Debug output.')
    for field in ('timeout_ms', 'total_timeout_ms'):
        value = sdk.get(field)
        runtime = runtime.replace('__' + field.upper() + '_PARAM__', f'{field}~ : Int32 = {value}' if value is not None else f'{field}? : Int32')
        argument = field + ('~' if value is not None else '?') if field == 'timeout_ms' else 'total_ms' + ('' if value is not None else '?') + '=total_timeout_ms'
        runtime = runtime.replace('__' + field.upper() + '_ARG__', argument)
    timeout_doc = f"The default per-attempt timeout is {sdk['timeout_ms']} ms." if 'timeout_ms' in sdk else 'No per-attempt timeout is set by default.'
    timeout_doc += f" The default total timeout is {sdk['total_timeout_ms']} ms." if 'total_timeout_ms' in sdk else ' No total timeout is set by default.'
    runtime = runtime.replace('__TIMEOUT_DOC__', timeout_doc)
    files = {
        'client_gen.mbt': HEADER + runtime + '\n' + auth_code + '\n' + metadata_code,
        'failures_gen.mbt': HEADER + failure + '\n' + error_code,
        'retry_gen.mbt': HEADER + '///|\n/// SDK retry default; a Refused failure means not processed.\npub fn default_retry() -> @client.RetryPolicy {\n' + retry_source(sdk.get('retry')) + '\n}\n',
    }
    wrappers = []
    pagination = []
    for op, raw, _ in operations(doc, ir):
        if sdk.get('operation_wrappers', True):
            wrappers.append(wrapper(op, raw, prefix, client, auth_headers, names[op.operation_id]))
        if 'x-moonbit-paginate' in raw:
            pagination.append(paginator(op, raw, ir, prefix, client, auth_headers, names[op.operation_id]))
    if wrappers:
        files['operations_gen.mbt'] = HEADER + '\n'.join(wrappers)
        if any('match decode_text(' in source for source in wrappers):
            files['operations_gen.mbt'] += '''
///|
fn decode_text(head : @http.ResponseHead, body : Bytes) -> Result[String, @client.ResponseFailure] {
  try { Ok(@utf8.decode(body)) } catch {
    _ => Err(@client.Deserialization(head, message="invalid UTF-8 response body", body=body[:body.length().min(@client.max_error_body)].to_owned()))
  }
}
'''
    files['paginate_gen.mbt'] = HEADER + (TEMPLATES / 'paginate.mbt').read_text().replace('__CLIENT__', client) + '\n'.join(pagination)
    files['contract_gen.mbt'] = HEADER + (TEMPLATES / 'contract.mbt').read_text().replace('__CLIENT__', client).replace('__BASE_URL__', quote(sdk['base_url'])).replace('__PROVIDER__', quote(sdk['name']))
    files['contract_gen.mbt'] += contract_auth(choices, client, doc)
    files['contract_gen.mbt'] += contract_operations(doc, ir, sdk, client, choices)
    files['contract_gen.mbt'] += contract_error(doc, ir, client)
    if 'timeout_ms' in sdk:
        files['contract_gen.mbt'] += f'''///|
test "generated provider timeout default and caller override" {{
  let seen : Array[Int32?] = []
  let backend = @client.from_fn((_, options) => {{ seen.push(options.timeout_ms); @http.Response::new(200) }})
  let sdk = {client}::new(backend, @sim.FakeClock::new())
  ignore(@driver.run_sync(() => sdk.send(@http.Request::get("/contract-test"))))
  let sdk = {client}::new(backend, @sim.FakeClock::new(), timeout_ms=1234)
  ignore(@driver.run_sync(() => sdk.send(@http.Request::get("/contract-test"))))
  assert_eq(seen, [Some({sdk['timeout_ms']}), Some(1234)])
}}
'''
    if sdk.get('retry'):
        assertion = 'assert_eq(default_retry(), ' + retry_source(sdk['retry']) + ')\nignore(count)\nignore(clock)'
    else:
        assertion = 'assert_eq(count.val, 2)\nassert_eq(clock.slept().length(), 1)\nassert_eq(default_retry(), @client.RetryPolicy::conservative())'
    files['contract_gen.mbt'] = files['contract_gen.mbt'].replace('__RETRY_ASSERT__', assertion)
    files['contract_gen.mbt'] = files['contract_gen.mbt'].replace('assert_eq(', 'try! assert_eq(').replace('assert_true(', 'try! assert_true(').replace('assert_false(', 'try! assert_false(')
    files = {name: qualify(source) for name, source in files.items()}
    combined = '\n'.join(files.values()) + '\n'.join((vocabulary_files or {}).values())
    imports = {
        'http': 'gaato/mttp_core', 'client': 'gaato/mttp_core/client', 'rt': 'gaato/mttp_core/rt',
        'debug': 'moonbitlang/core/debug', 'utf8': 'moonbitlang/core/encoding/utf8', 'json': 'moonbitlang/core/json',
        'sse': 'gaato/mttp_core/sse', 'sdkjson': 'gaato/mttp_core/jsonkit', 'multipart': 'gaato/mttp_core/multipart',
        'gen': sdk['module'] + '/gen',
        'sim': 'gaato/mttp_core/sim', 'driver': 'gaato/mttp_core/driver',
    }
    production = combined
    lines = [f'  {quote(path)}' + (f' @{alias}' if alias != path.rsplit('/', 1)[-1] else '') + ',' for alias, path in imports.items() if '@' + alias + '.' in production]
    lines.extend('  ' + quote(path) + ',' for path in sdk.get('extra_imports', []))
    files['moon.pkg'] = HEADER + 'import {\n' + '\n'.join(lines) + '\n}\n\noptions(\n  "allow-experimental-packages": [ "gaato/mttp_core/driver" ],\n)\n'
    return files


def sample_json(schema, doc, seen=()):
    if '$ref' in schema:
        ref = schema['$ref']
        if ref in seen:
            return None
        current = doc
        for part in ref[2:].split('/'):
            current = current[part.replace('~1', '/').replace('~0', '~')]
        return sample_json(current, doc, (*seen, ref))
    if 'enum' in schema:
        return schema['enum'][0]
    if schema.get('x-moonbit-int-string') in ('int64', 'uint64'):
        return '1'
    for key in ('anyOf', 'oneOf'):
        if key in schema:
            return sample_json(schema[key][0], doc, seen)
    kind = schema.get('type')
    if kind == 'object' or 'properties' in schema:
        return {name: sample_json(value, doc, seen) for name, value in schema.get('properties', {}).items() if name in schema.get('required', [])}
    return {'string': 'example', 'integer': 1, 'number': 1, 'boolean': True, 'array': []}.get(kind)


def contract_error(doc, ir, client):
    import json
    for op, raw, _ in operations(doc, ir):
        for status, response in sorted(raw.get('responses', {}).items(), key=lambda item: error_priority(item[0])):
            if not error_status(status):
                continue
            schema = next((m['schema'] for kind, m in response.get('content', {}).items() if json_response_media(kind) and 'schema' in m), None)
            if schema is None:
                continue
            body = quote(json.dumps(sample_json(schema, doc)))
            code = int(status) if str(status).isdigit() else int(str(status)[0]) * 100 if str(status).upper().endswith('XX') else 400
            return f'''///|
test "generated typed HTTP error body" {{
  let body = @utf8.encode({body})
  let backend = @client.from_fn((_, _) => @http.Response::new({code}, body=Bytes(body)))
  let sdk = {client}::new(backend, @sim.FakeClock::new(), retry=@client.RetryPolicy::none())
  match @driver.run_sync(() => sdk.send(@http.Request::get("/contract-test"), operation={quote(op.operation_id)})) {{
    Err(Http(failure)) => {{ assert_true(failure.typed is Some(_)); assert_eq(failure.body, body) }}
    _ => fail("expected typed HTTP error")
  }}
}}
'''
    return ''


def contract_operations(doc, ir, sdk, client, choices):
    tests = []
    for op, raw, item in operations(doc, ir):
        path = re.sub(r'\{[^}]+\}', 'example', op.path)
        servers = raw.get('servers', item.get('servers', []))
        server = servers[0]['url'] if servers else ''
        # Absolute pins, relative path overrides and constructor overrides all
        # have externally visible expectations in these backend tests.
        base = server or sdk['base_url']
        if base.startswith('/'):
            from urllib.parse import urljoin
            base = urljoin(sdk['base_url'], base)
        expected = base.rstrip('/') + '/' + path.lstrip('/')
        tests.append(f'''///|
test "generated route and server {op.operation_id}" {{
  let seen = Ref("")
  let backend = @client.from_fn((request, _) => {{ seen.val = request.url; @http.Response::new(200) }})
  let sdk = {client}::new(backend, @sim.FakeClock::new())
  ignore(@driver.run_sync(() => sdk.send(@http.Request::new(@http.Method::parse({quote(op.method)}), {quote(path)}))))
  assert_eq(seen.val, {quote(expected)})
}}
''')
        if server:
            tests.append(f'''///|
test "generated server replacement {op.operation_id}" {{
  let backend = @client.from_fn((request, _) => {{ assert_eq(request.url, "https://replacement.example" + {quote(path)}); @http.Response::new(200) }})
  let sdk = {client}::new(backend, @sim.FakeClock::new(), server_urls={{ {quote(server)}: "https://replacement.example" }})
  ignore(@driver.run_sync(() => sdk.send(@http.Request::new(@http.Method::parse({quote(op.method)}), {quote(path)}))))
}}
''')
        if raw.get('security', doc.get('security')) == []:
            for auth in choices:
                if auth['kind'] == 'none':
                    continue
                ctor = 'Auth::' + auth_constructor(auth, doc) + ('("u", "p")' if auth['kind'] == 'basic' else '("secret")')
                check = 'assert_false(request.url.contains("secret"))' if auth['kind'] == 'query' else f'assert_eq(request.headers.get({quote(auth.get("name", "authorization"))}), None)'
                tests.append(f'''///|
test "generated public operation {op.operation_id} {auth_constructor(auth, doc)}" {{
  let backend = @client.from_fn((request, _) => {{ {check}; @http.Response::new(200) }})
  let sdk = {client}::new(backend, @sim.FakeClock::new(), auth={ctor})
  ignore(@driver.run_sync(() => sdk.send(@http.Request::new(@http.Method::parse({quote(op.method)}), {quote(path)}))))
}}
''')
    return '\n'.join(tests)


def validate_pagination(op, config):
    if set(config) - {'kind', 'items', 'next', 'param'} or config.get('kind') not in ('cursor', 'url') or not all(isinstance(config.get(k), str) and config[k] for k in ('items', 'next')):
        raise ValueError(f'{op.operation_id}: invalid x-moonbit-paginate')
    if config['kind'] == 'cursor' and not config.get('param'):
        raise ValueError(f'{op.operation_id}: cursor pagination needs param')


def paginator_item_type(ir, op, config):
    current = op.response_type
    declarations = {declaration.name: declaration for declaration in ir.declarations}
    for part in config['items'].split('.'):
        declaration = declarations.get(current.name) if current else None
        if isinstance(declaration, Struct):
            current = next((field.type for field in declaration.fields if field.json_name == part), None)
        elif current and current.kind == 'map':
            current = current.item
        else:
            return None
    return current.item if current and current.kind == 'array' else None


def pagination_notes(doc, ir):
    notes = []
    for op, raw, _ in operations(doc, ir):
        config = raw.get('x-moonbit-paginate')
        if config is not None:
            validate_pagination(op, config)
            item = paginator_item_type(ir, op, config)
            if item is None or item.kind == 'Json':
                pointer = '/paths/' + op.path.replace('~', '~0').replace('/', '~1') + '/' + op.method.lower() + '/x-moonbit-paginate/items'
                notes.append(Note(pointer, 'pagination item schema is not representable as a concrete type; items fall back to Json'))
    return notes


def paginator(op, raw, ir, prefix, client, auth_headers, name):
    config = raw['x-moonbit-paginate']
    validate_pagination(op, config)
    item = paginator_item_type(ir, op, config)
    item_type = qualified_ref(item, prefix) if item else 'Json'
    params, request = request_parts(op, raw, prefix, auth_headers)
    request = validated_request(op, request, prefix, paginator=True)
    params = 'self : ' + client + (', ' + params if params else '')
    kind = 'NextUrl' if config['kind'] == 'url' else 'Cursor(' + quote(config['param']) + ')'
    return f'''///|
/// Pages {op.operation_id}, building the first request from the operation parameters.
pub fn {client}::{name}_pages({params}) -> @client.Paginator[{item_type}, Failure]{' raise @multipart.MultipartError' if op.multipart_fields else ''} {{
  let first = {request}
  self.paginate(first, kind={kind}, items={quote(config['items'])}, next={quote(config['next'])}, operation={quote(op.operation_id)})
}}
'''


def contract_auth(choices, client, doc=None):
    tests = []
    for a in choices:
        if a['kind'] == 'none':
            continue
        auth = 'Auth::' + auth_constructor(a, doc) + ('("user", "pass")' if a['kind'] == 'basic' else '("test-secret")')
        key = a.get('name', 'authorization').lower()
        value = {'bearer': 'Bearer test-secret', 'basic': 'Basic dXNlcjpwYXNz'}.get(a['kind'], 'test-secret')
        check = f'assert_eq(request.headers.get({quote(key)}), Some({quote(value)}))' if a['kind'] != 'query' else f'assert_true(request.url.contains({quote(key + "=test-secret")}))'
        redirect_check = f'assert_eq(request.headers.get({quote(key)}), if same_origin {{ Some({quote(value)}) }} else {{ None }})' if a['kind'] != 'query' else '()'
        diagnostics = f'''
        assert_true(request.attributes.get(@http.credential_headers).unwrap_or([]).contains({quote(key)}))
        let curl = @client.request(request).response(@client.as_bytes()).to_curl()
        assert_false(curl.contains({quote(value)}))
''' if a['kind'] != 'query' else ''
        invalid = ''
        if a['kind'] in ('bearer', 'header'):
            invalid = f'''
  let backend = @client.from_fn((_, _) => abort("invalid credentials reached the backend"))
  for value in [" leading", "trailing\\t"] {{
    let sdk = {client}::new(backend, @sim.FakeClock::new(), auth=Auth::{auth_constructor(a, doc)}(value))
    assert_true(@driver.run_sync(() => sdk.send(@http.Request::get("/contract-test"))) is Err(Validation(parameter="headers", ..)))
  }}
'''
        tests.append(f'''///|
test "generated from_client auth {auth_constructor(a, doc)} and redirect boundaries" {{
  for same_origin in [true, false] {{
    let count = Ref(0)
    let backend = @client.from_fn((request, _) => {{
      count.val += 1
      if count.val == 1 {{
        {check}{diagnostics}
        @http.Response::new(302, headers=@http.Headers::of([("location", if same_origin {{ "/next" }} else {{ "https://other.example/next" }})]))
      }} else {{
        {redirect_check}
        @http.Response::new(200, body=Bytes(b"ok"))
      }}
    }})
    let config = {{ ..@client.RedirectConfig::default(), credential_headers: [] }}
    let runtime = @client.Client::new(backend, @sim.FakeClock::new(), redirect=config)
    let sdk = {client}::from_client(runtime, auth={auth})
    assert_true(@driver.run_sync(() => sdk.send(@http.Request::get("/contract-test"))) is Ok(_))
    assert_eq(count.val, 2)
  }}{invalid}
}}
''')
    return '\n'.join(tests)
