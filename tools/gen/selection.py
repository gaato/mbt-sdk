"""One declarative operation selector, shared by generation, census and pins."""
from .ir import HTTP_METHODS, derive_operation_id


def validate(selection):
    if selection is None:
        return
    if not isinstance(selection, dict) or set(selection) - {'paths', 'operations', 'excludes'}:
        raise ValueError('selection accepts only paths, operations and excludes')
    for key in ('paths', 'operations'):
        values = selection.get(key, [])
        if not isinstance(values, list) or any(not isinstance(v, str) or not v.strip() or '\n' in v for v in values):
            raise ValueError(f'selection.{key} must contain nonempty single-line strings')
        if len(values) != len(set(values)):
            raise ValueError(f'selection.{key} contains duplicates')
    if any(not path.startswith('/') for path in selection.get('paths', [])):
        raise ValueError('selection paths must be absolute path prefixes')
    excludes = selection.get('excludes', [])
    if not isinstance(excludes, list):
        raise ValueError('selection.excludes must be an array')
    seen = set()
    for exclusion in excludes:
        if not isinstance(exclusion, dict) or set(exclusion) != {'operation', 'reason'} or any(not isinstance(v, str) or not v.strip() or '\n' in v for v in exclusion.values()):
            raise ValueError('every exclusion needs a nonempty operation and reason')
        if exclusion['operation'] in seen:
            raise ValueError('duplicate selection exclusion')
        seen.add(exclusion['operation'])


def apply(doc, selection):
    """Union of prefixes/IDs, then excludes; no includes means all operations.

    Fail on stale selectors rather than silently shrinking a product. Derived
    IDs follow the same rule as the generator. Operates after overlays.
    """
    validate(selection)
    if selection is None:
        return None
    paths = selection.get('paths', [])
    wanted = set(selection.get('operations', []))
    excluded = {item['operation'] for item in selection.get('excludes', [])}
    found, matched, selected = set(), set(), set()
    for path, item in doc.get('paths', {}).items():
        for method, operation in item.items():
            if method not in HTTP_METHODS or not isinstance(operation, dict):
                continue
            operation_id = operation.get('operationId') or derive_operation_id(method, path)
            found.add(operation_id)
            prefixes = {prefix for prefix in paths if operation.get('x-moonbit-request-path', path).startswith(prefix)}
            matched.update(prefixes)
            include = (not paths and not wanted or bool(prefixes) or operation_id in wanted) and operation_id not in excluded
            operation['x-moonbit-include'] = include
            if include:
                selected.add(operation_id)
    missing = (wanted | excluded) - found
    if missing:
        raise ValueError('unknown selection operationId(s): ' + ', '.join(sorted(missing)))
    if set(paths) - matched:
        raise ValueError('unmatched selection path prefix(es): ' + ', '.join(sorted(set(paths) - matched)))
    if not selected:
        raise ValueError('selection contains no operations')
    return selected


def selected_document(doc, selection, *, identities=None):
    """Filter raw pin data by selections resolved against overlaid identities.

    Retain the raw host/authentication baseline: overlays can change operation
    IDs and request paths without approving changes to the upstream pins.
    """
    if selection is None:
        return doc
    import copy
    result = copy.deepcopy(doc)
    selected = copy.deepcopy(identities) if identities is not None else result
    apply(selected, selection)
    for path in list(result.get('paths', {})):
        item = result['paths'][path]
        chosen = selected.get('paths', {}).get(path, {})
        for method in HTTP_METHODS:
            if method in item and not chosen.get(method, {}).get('x-moonbit-include'):
                del item[method]
        if not any(method in item for method in HTTP_METHODS):
            del result['paths'][path]
    return result
