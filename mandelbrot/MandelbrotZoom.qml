import QtQuick

// One frame of the endless zoom.
//
// The camera is not really "moving": it walks exactly one renormalisation
// period of a Misiurewicz point, zooming by |lambda| while turning by
// -arg(lambda).  Those two together map the picture onto itself, so phase 1.0
// renders the same image as phase 0.0 and the loop has no seam.  On the way
// through, the picture morphs, and that morph is the zoom you see.
//
// The point's own constants -- the zoom per loop, the rotation, the escape-step
// drift, the starting depth and the iteration budget -- are baked into the
// generated shader, so picking a point is picking a shader and nothing here has
// to agree with the maths by hand.
//
// The root is the ShaderEffect itself rather than an Item wrapping one: a
// wrapping id can be null for a moment while the scene is being torn down, and
// every binding below would have to guard against that.
ShaderEffect {
  id: zoom

  // Position in the loop, [0,1). Kept by the service so every screen agrees.
  property real phase: 0

  // height / width of this surface.
  property real aspect: 1.0

  // Directory holding the generated shaders, and which one to draw. Passed in
  // rather than written as a relative URL: a relative one resolves against
  // whatever base the importing document happened to have, which breaks when
  // the component is reached through a symlink or another import path.
  property string shaderDir: ""
  property string pointName: "snowflake"

  // Fraction of device resolution the shader runs at. The zoom is ALU bound, so
  // this is the cost dial; see the layer block below for why it has to go
  // through layer.textureSize.
  property real renderScale: 0.5

  // A ThemeColors, normally. Null keeps the built-in ramp.
  property var colors: null

  // Palette cycles per escape step.
  property real bandScale: 1.0



  fragmentShader: zoom.shaderDir + zoom.pointName + ".frag.qsb"

  // Qt Quick runs a ShaderEffect once per *device* pixel whatever the item's
  // geometry or transform says, so a Scale alone changes nothing. Rendering into
  // a smaller layer texture and letting the scene graph stretch it is the only
  // way to actually cut the fragment work. Measured on the Intel iGPU at
  // 1920x1080: 26 ms a frame at full size, 19 ms at half, 16.6 ms (60 Hz, the
  // floor) at 0.35.
  readonly property real effectiveScale: Math.max(0.25, Math.min(1.0, renderScale))
  layer.enabled: effectiveScale < 1.0
  layer.smooth: true
  layer.textureSize: Qt.size(Math.max(2, Math.round(width * effectiveScale)),
                             Math.max(2, Math.round(height * effectiveScale)))

  property real uPhase: zoom.phase
  property real uAspect: zoom.aspect
  // Band frequency follows the sampling rate. At half resolution the colour
  // field is sampled half as often, so bands that were one pixel wide land
  // between samples and shimmer as the picture moves; widening them with the
  // scale keeps the same number of bands per screen pixel instead.
  property real uPalScale: zoom.bandScale * zoom.effectiveScale

  property color uPal0: zoom.colors ? zoom.colors.ramp0 : "#c678dd"
  property color uPal1: zoom.colors ? zoom.colors.ramp1 : "#56b6c2"
  property color uPal2: zoom.colors ? zoom.colors.ramp2 : "#e5c07b"
  property color uPal3: zoom.colors ? zoom.colors.ramp3 : "#61afef"
}
