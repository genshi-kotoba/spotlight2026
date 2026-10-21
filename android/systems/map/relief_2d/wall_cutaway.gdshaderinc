// All coordinates are renderer-local projected pixels, independent of camera zoom.
uniform int cut_count = 0;
uniform int cut_wall_edges[20]; // Session-owned physical wall edges, never fog/gate borders.
uniform bool cut_contact_enabled = true;
uniform vec4 cut_targets[20]; // actor: center/half extents; ground: center/weight/6 edge bits
uniform vec3 cut_depths[20];
uniform vec3 cut_edges_a[20]; // Current authorized shared-edge openness.
uniform vec3 cut_edges_b[20];
uniform vec4 cut_inverse;
uniform float cut_opacity = 0.14;
uniform vec2 cut_actor_feet;
uniform float cut_radius = 60.0;
uniform bool cut_body_mask_enabled = false;
uniform sampler2D cut_body_mask : filter_linear, repeat_disable, hint_default_black;
uniform vec4 cut_body_rect; // Stable all-animation footprint, renderer-local pixels.

float body_aperture(vec2 p, vec2 delta, vec2 half_size) {
	float original = 1.0 - smoothstep(0.57, 1.0, length(delta / half_size));
	if (!cut_body_mask_enabled || original <= 0.0) return original;
	vec2 uv = (p - cut_body_rect.xy) / cut_body_rect.zw;
	float fitted = 0.0;
	if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
		fitted = texture(cut_body_mask, uv).r;
	}
	// Preserve the old near-foot aperture. This footprint follows the actual
	// interpolated feet, not the nearest cell, so crossing a hex cannot switch it.
	vec2 offset = p - cut_actor_feet;
	vec2 plane = abs(vec2(dot(cut_inverse.xy, offset), dot(cut_inverse.zw, offset)));
	float footprint = max(plane.y / 0.8660254, plane.x + plane.y / 1.7320508);
	float foot_guard = 1.0 - smoothstep(0.78, 1.25, footprint);
	return mix(min(original, fitted), original, foot_guard);
}

float ground_aperture(vec2 delta, vec3 joined_a, vec3 joined_b) {
	vec2 plane = vec2(dot(cut_inverse.xy, delta), dot(cut_inverse.zw, delta));
	// Signed half-spaces in HexCoord.DIRS order. Adjacent authorized apertures
	// overlap at their shared edge, while the exterior still feathers inward.
	vec3 edge = vec3(plane.x + plane.y / 1.7320508,
		plane.x - plane.y / 1.7320508, -plane.y / 0.8660254);
	vec3 a = (edge - mix(vec3(0.78), vec3(1.0), joined_a)) / mix(vec3(0.22), vec3(0.25), joined_a);
	vec3 b = (-edge - mix(vec3(0.78), vec3(1.0), joined_b)) / mix(vec3(0.22), vec3(0.25), joined_b);
	vec3 boundary = max(a, b);
	return 1.0 - smoothstep(0.0, 1.0, max(boundary.x, max(boundary.y, boundary.z)));
}

float cut_field(vec2 p, float face_depth, bool wall_surface) {
	float body = 0.0;
	float ground = 0.0;
	// Keep the foot core clear, but start fading the path margin earlier.
	// The same outer support and authorized hex/depth masks still bound it.
	float nearby = 1.0 - smoothstep(cut_radius * 0.65, cut_radius * 2.25, distance(p, cut_actor_feet));
	for (int i = 0; i < 20; i++) {
		if (i >= cut_count) break;
		if (face_depth <= dot(cut_depths[i], vec3(p, 1.0)) + 0.0003) continue;
		vec2 delta = p - cut_targets[i].xy;
		float aperture;
		if (i == 0) {
			// Keep the sprite readable, but spread the transition through the
			// surrounding margin instead of revealing a solid oval cutout.
			body = body_aperture(p, delta, cut_targets[i].zw);
		} else {
			aperture = ground_aperture(delta, cut_edges_a[i], cut_edges_b[i]);
			ground = max(ground, aperture * nearby * cut_targets[i].z);
		}
	}
	// A body-only aperture reveals background masonry even where no nearby
	// path target contributes. Only the character restore may use that field.
	// On walls, the original continuous path field must authorize any opening;
	// the body only strengthens that opening. No new per-cell mask or seam.
	if (wall_surface) body *= ground;
	return body + ground * (1.0 - body);
}

float cut_coverage(vec2 p, float face_depth) {
	return cut_field(p, face_depth, false);
}

float wall_cut_coverage(vec2 p, float face_depth) {
	return cut_field(p, face_depth, true);
}

// Evaluated on the real ground receiver, not an overlay over foreground art.
// Thus physical occlusion, fog, solar tint and dynamic ground shadows remain
// in the original painter pipeline. The outer band edge is the actual wall
// footprint (zero offset). A 0.006R core feathers to zero at 0.035R INTO the
// floor; the cue does not move or expand the physical boundary. The receiver
// has no adjacent wall-root height, so retain the existing known edge/depth
// eligibility rather than infer whether a neighboring wall is cut away.
float wall_contact(vec2 p, float depth) {
	if (!cut_contact_enabled || cut_count <= 1) return 0.0;
	float nearby = 1.0 - smoothstep(cut_radius * 1.2, cut_radius * 2.25, distance(p, cut_actor_feet));
	if (nearby <= 0.0) return 0.0;
	float result = 0.0;
	for (int i = 1; i < 20; i++) {
		if (i >= cut_count) break;
		int mask = cut_wall_edges[i];
		if (mask == 0 || abs(depth - dot(cut_depths[i], vec3(p, 1.0))) > 0.0005) continue;
		vec2 delta = p - cut_targets[i].xy;
		vec2 plane = vec2(dot(cut_inverse.xy, delta), dot(cut_inverse.zw, delta));
		vec3 e = vec3(plane.x + plane.y / 1.7320508, plane.x - plane.y / 1.7320508, -plane.y / 0.8660254);
		if (max(abs(e.x), max(abs(e.y), abs(e.z))) > 1.0001) continue;
		float distance_inside = 2.0;
		for (int j = 0; j < 6; j++) {
			if ((mask & (1 << j)) == 0) continue;
			float edge = j < 3 ? e[j] : -e[j - 3];
			distance_inside = min(distance_inside, (1.0 - edge) * 0.8660254);
		}
		float band = 1.0 - smoothstep(0.006, 0.035, distance_inside);
		result = max(result, band * nearby * cut_targets[i].z);
	}
	return result;
}
