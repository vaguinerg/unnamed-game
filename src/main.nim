import raylib, raymath, ./admob
import std/math

when not defined(android):
  import std/os
  setCurrentDir getAppDir()

# ----------------------------------------------------------------------------------
# Constantes
# ----------------------------------------------------------------------------------
const
  Gravity       = 32.0'f32
  MaxSpeed      = 20.0'f32
  CrouchSpeed   =  5.0'f32
  JumpForce     = 12.0'f32
  MaxAccel      = 150.0'f32
  Friction      =  0.86'f32
  AirDrag       =  0.98'f32
  Control       = 15.0'f32
  CrouchHeight  =  0.0'f32
  StandHeight   =  1.0'f32
  BottomHeight  =  0.5'f32

# ----------------------------------------------------------------------------------
# Tipos
# ----------------------------------------------------------------------------------
type
  Body = object
    position:   Vector3
    velocity:   Vector3
    dir:        Vector3
    isGrounded: bool

# ----------------------------------------------------------------------------------
# Variáveis globais
# ----------------------------------------------------------------------------------
var
  sensitivity   = Vector2(x: 0.001'f32, y: 0.001'f32)
  player        = Body()
  lookRotation  = Vector2(x: 0, y: 0)
  headTimer     = 0.0'f32
  walkLerp      = 0.0'f32
  headLerp      = StandHeight
  lean          = Vector2(x: 0, y: 0)

# ----------------------------------------------------------------------------------
# Atualiza física/movimento do corpo
# ----------------------------------------------------------------------------------
proc updateBody(body: var Body; rot: float32; side, forward: int; jumpPressed, crouchHold: bool) =
  var input = Vector2(x: float32(side), y: float32(-forward))

  let delta = getFrameTime()

  if not body.isGrounded:
    body.velocity.y -= Gravity * delta

  if body.isGrounded and jumpPressed:
    body.velocity.y  = JumpForce
    body.isGrounded  = false

  let front = Vector3(x: sin(rot),  y: 0.0'f32, z: cos(rot))
  let right = Vector3(x: cos(-rot), y: 0.0'f32, z: sin(-rot))

  let desiredDir = Vector3(
    x: input.x * right.x + input.y * front.x,
    y: 0.0'f32,
    z: input.x * right.z + input.y * front.z)

  body.dir = lerp(body.dir, desiredDir, Control * delta)

  let decel = if body.isGrounded: Friction else: AirDrag
  var hvel = Vector3(x: body.velocity.x * decel, y: 0.0'f32, z: body.velocity.z * decel)

  let hvelLength = length(hvel)
  if hvelLength < MaxSpeed * 0.01'f32:
    hvel = Vector3(x: 0, y: 0, z: 0)

  let speed    = dotProduct(hvel, body.dir)
  let maxSpd   = if crouchHold: CrouchSpeed else: MaxSpeed
  let accel    = clamp(maxSpd - speed, 0.0'f32, MaxAccel * delta)
  hvel.x += body.dir.x * accel
  hvel.z += body.dir.z * accel

  body.velocity.x = hvel.x
  body.velocity.z = hvel.z

  body.position.x += body.velocity.x * delta
  body.position.y += body.velocity.y * delta
  body.position.z += body.velocity.z * delta

  if body.position.y <= 0.0'f32:
    body.position.y  = 0.0'f32
    body.velocity.y  = 0.0'f32
    body.isGrounded  = true

# ----------------------------------------------------------------------------------
# Atualiza câmera FPS
# ----------------------------------------------------------------------------------
proc updateCameraFPS(camera: var Camera) =
  let up           = Vector3(x: 0.0'f32, y: 1.0'f32, z: 0.0'f32)
  let targetOffset = Vector3(x: 0.0'f32, y: 0.0'f32, z: -1.0'f32)

  var yaw = rotateByAxisAngle(targetOffset, up, lookRotation.x)

  var maxAngleUp = angle(up, yaw) - 0.001'f32
  if -lookRotation.y > maxAngleUp:
    lookRotation.y = -maxAngleUp

  var maxAngleDown = angle(negate(up), yaw) * -1.0'f32 + 0.001'f32
  if -lookRotation.y < maxAngleDown:
    lookRotation.y = -maxAngleDown

  let right = normalize(crossProduct(yaw, up))

  var pitchAngle = -lookRotation.y - lean.y
  pitchAngle = clamp(pitchAngle, -PI.float32 / 2.0'f32 + 0.0001'f32,
                                  PI.float32 / 2.0'f32 - 0.0001'f32)
  let pitch = rotateByAxisAngle(yaw, right, pitchAngle)

  let headSin = sin(headTimer * PI.float32)
  let headCos = cos(headTimer * PI.float32)
  const stepRotation = 0.01'f32

  camera.up = rotateByAxisAngle(up, pitch, headSin * stepRotation + lean.x)

  const bobSide = 0.1'f32
  const bobUp   = 0.15'f32
  var bobbing   = scale(right, headSin * bobSide)
  bobbing.y     = abs(headCos * bobUp)

  camera.position = add(camera.position, scale(bobbing, walkLerp))
  camera.target   = add(camera.position, pitch)

# ----------------------------------------------------------------------------------
# Desenha o nível
# ----------------------------------------------------------------------------------
proc drawLevel() =
  const floorExtent = 25
  const tileSize    = 5.0'f32
  const tileColor1  = Color(r: 150, g: 200, b: 200, a: 255)

  for y in -floorExtent ..< floorExtent:
    for x in -floorExtent ..< floorExtent:
      let oddY = (y and 1) != 0
      let oddX = (x and 1) != 0
      if oddY and oddX:
        drawPlane(Vector3(x: float32(x) * tileSize, y: 0.0'f32, z: float32(y) * tileSize),
                  Vector2(x: tileSize, y: tileSize), tileColor1)
      elif (not oddY) and (not oddX):
        drawPlane(Vector3(x: float32(x) * tileSize, y: 0.0'f32, z: float32(y) * tileSize),
                  Vector2(x: tileSize, y: tileSize), LightGray)

  const towerSize  = Vector3(x: 16.0'f32, y: 32.0'f32, z: 16.0'f32)
  const towerColor = Color(r: 150, g: 200, b: 200, a: 255)

  var towerPos = Vector3(x: 16.0'f32, y: 16.0'f32, z: 16.0'f32)
  drawCube(towerPos, towerSize, towerColor);   drawCubeWires(towerPos, towerSize, DarkBlue)
  towerPos.x *= -1
  drawCube(towerPos, towerSize, towerColor);   drawCubeWires(towerPos, towerSize, DarkBlue)
  towerPos.z *= -1
  drawCube(towerPos, towerSize, towerColor);   drawCubeWires(towerPos, towerSize, DarkBlue)
  towerPos.x *= -1
  drawCube(towerPos, towerSize, towerColor);   drawCubeWires(towerPos, towerSize, DarkBlue)

  drawSphere(Vector3(x: 300.0'f32, y: 300.0'f32, z: 0.0'f32), 100.0'f32,
             Color(r: 255, g: 0, b: 0, a: 255))

# ----------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------
setTraceLogLevel(None)
setConfigFlags(flags(WindowResizable, Msaa4xHint, VsyncHint))
initWindow(800, 600, "raylib [core] example - 3d camera fps")

var camera = Camera(
  fovy:       60.0'f32,
  projection: Perspective,
  position:   Vector3(x: player.position.x,
                      y: player.position.y + BottomHeight + headLerp,
                      z: player.position.z))

updateCameraFPS(camera)
disableCursor()

while not windowShouldClose():
  # Atualização
  let mouseDelta = getMouseDelta()
  lookRotation.x -= mouseDelta.x * sensitivity.x
  lookRotation.y += mouseDelta.y * sensitivity.y

  let sideway  = int(isKeyDown(D)) - int(isKeyDown(A))
  let fwd      = int(isKeyDown(W)) - int(isKeyDown(S))
  let crouching = isKeyDown(LeftControl)

  updateBody(player, lookRotation.x, sideway, fwd,
             isKeyPressed(Space), crouching)

  let delta = getFrameTime()
  headLerp     = lerp(headLerp, if crouching: CrouchHeight else: StandHeight, 20.0'f32 * delta)
  camera.position = Vector3(x: player.position.x,
                             y: player.position.y + BottomHeight + headLerp,
                             z: player.position.z)

  if player.isGrounded and (fwd != 0 or sideway != 0):
    headTimer += delta * 3.0'f32
    walkLerp   = lerp(walkLerp, 1.0'f32, 10.0'f32 * delta)
    camera.fovy = lerp(camera.fovy, 55.0'f32, 5.0'f32 * delta)
  else:
    walkLerp    = lerp(walkLerp, 0.0'f32, 10.0'f32 * delta)
    camera.fovy = lerp(camera.fovy, 60.0'f32, 5.0'f32 * delta)

  lean.x = lerp(lean.x, float32(sideway) * 0.02'f32,  10.0'f32 * delta)
  lean.y = lerp(lean.y, float32(fwd)     * 0.015'f32, 10.0'f32 * delta)

  updateCameraFPS(camera)

  # Desenho
  drawing:
    clearBackground(RayWhite)
    mode3D(camera):
      drawLevel()

    drawRectangle(5, 5, 330, 75, fade(SkyBlue, 0.5'f32))
    drawRectangleLines(5, 5, 330, 75, Blue)
    drawText("Camera controls:", 15, 15, 10, Black)
    drawText("- Move keys: W, A, S, D, Space, Left-Ctrl", 15, 30, 10, Black)
    drawText("- Look around: arrow keys or mouse", 15, 45, 10, Black)
    let hvel2d = Vector2(x: player.velocity.x, y: player.velocity.z)
    drawText("- Velocity Len: " & $length(hvel2d), 15, 60, 10, Black)

closeWindow()
