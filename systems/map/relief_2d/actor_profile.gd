extends RefCounted
## Visual body and distance-based gait use the current 100% preview scale.
## Collision remains the shared planar Session.FOOT_RADIUS, independent of art.
const VISUAL_SCALE := 1.0
const HEIGHT := 1.1 * VISUAL_SCALE
const FOOT_RADIUS := 0.18 * VISUAL_SCALE
const MOVE_SPEED := 2.1 # Shared planar default; visual scale does not alter speed.
const STRIDE_DISTANCE := 1.4 * VISUAL_SCALE
