///|
// This package moved to gaato/http/multipart in sdk-runtime 0.5.0 and is kept
// for one release as aliases of it; it goes in the next minor. The error
// constructors cannot be aliased: match them as `@http_multipart.<Name>`.

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {type Part}

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {type MultipartError}

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {apply}

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {encode}

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {encode_body}

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {encode_segments}

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {encode_segments_fresh}

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {join_segments}

///|
#deprecated("moved to gaato/http/multipart")
pub using @http_multipart {make_boundary}
