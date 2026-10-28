// AA-979 P2b clean-up (runbook 4.5): viewer-request function of the partner distribution (crm_edge.tf).
// The old agency host partner-<env>. answers 301 to the agency host portal. with the same path and query, except the
// CRM API paths /crm and /crm/* (the CI deploy gates and server-to-server callers POST there; a 301 would turn a POST
// into a GET). cloudfront-js-2.0. AGENCY_ORIGIN is filled in by Terraform (templatefile), no other template syntax here.
var AGENCY_ORIGIN = "${agency_origin}";

function queryString(qs) {
  var parts = [];
  var keys = Object.keys(qs || {});
  for (var i = 0; i < keys.length; i++) {
    var item = qs[keys[i]];
    var values = item.multiValue ? item.multiValue : [item];
    for (var j = 0; j < values.length; j++) {
      var v = values[j].value;
      parts.push(v === "" ? keys[i] : keys[i] + "=" + v);
    }
  }
  return parts.length ? "?" + parts.join("&") : "";
}

function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (uri === "/crm" || uri.indexOf("/crm/") === 0) {
    return request;
  }
  return {
    statusCode: 301,
    statusDescription: "Moved Permanently",
    headers: {
      location: { value: AGENCY_ORIGIN + uri + queryString(request.querystring) },
      "cache-control": { value: "max-age=3600" },
    },
  };
}
