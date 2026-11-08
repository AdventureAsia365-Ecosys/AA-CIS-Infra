// AA-1038 (S272): viewer-request function of the TripPlanner web distribution (tripplanner_web_edge.tf).
// Writes the viewer's own address into HEADER_NAME on every request, over any value the viewer sent. The TripPlanner
// rate rules of the ALB web ACL (modules/waf) key on this header: at the ALB the source address is CloudFront's, and
// X-Forwarded-For starts with whatever the viewer wrote. cloudfront-js-2.0. HEADER_NAME is filled in by Terraform
// (templatefile), no other template syntax here.
var HEADER_NAME = "${header_name}";

function handler(event) {
  var request = event.request;
  request.headers[HEADER_NAME] = { value: event.viewer.ip };
  return request;
}
