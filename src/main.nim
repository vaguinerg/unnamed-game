import raylib, raymath, ./admob
import std/math

when not defined(android):
  import std/os
  setCurrentDir getAppDir()

# Inicialização do jogo
setTraceLogLevel(None)
setConfigFlags(flags(WindowResizable, Msaa4xHint, VsyncHint))
initWindow(800, 600, "Cenário 3D - FPS Simples")
setTargetFPS(60)
disableCursor() # Esconde e trava o cursor do mouse para o controle FPS

# Configurações do jogador / câmera
const
  MouseSensitivity = 0.003'f32
  MoveSpeed = 8.0'f32
  Gravity = 20.0'f32
  JumpForce = 7.0'f32
  EyeHeight = 1.8'f32

var
  camera = Camera(
    position: Vector3(x: 0.0'f32, y: EyeHeight, z: 5.0'f32),
    target: Vector3(x: 0.0'f32, y: EyeHeight, z: 4.0'f32),
    up: Vector3(x: 0.0'f32, y: 1.0'f32, z: 0.0'f32),
    fovy: 60.0'f32,
    projection: Perspective
  )
  cameraAngleX = 0.0'f32 # Rotação horizontal (yaw)
  cameraAngleY = 0.0'f32 # Rotação vertical (pitch)
  velY = 0.0'f32
  isGrounded = true

while not windowShouldClose():
  let dt = getFrameTime()

  # 1. Controle da Câmera (Mouse)
  let mouseDelta = getMouseDelta()
  cameraAngleX += mouseDelta.x * MouseSensitivity
  cameraAngleY -= mouseDelta.y * MouseSensitivity
  
  # Limita a rotação vertical para não dar "looping" de cabeça para baixo
  cameraAngleY = clamp(cameraAngleY, -1.5'f32, 1.5'f32)

  # Direções baseadas no ângulo horizontal (plano XZ)
  let forwardX = sin(cameraAngleX)
  let forwardZ = -cos(cameraAngleX)
  let rightX = cos(cameraAngleX)
  let rightZ = sin(cameraAngleX)

  # 2. Movimentação do Jogador (WASD)
  var dx = 0.0'f32
  var dz = 0.0'f32

  if isKeyDown(W):
    dx += forwardX
    dz += forwardZ
  if isKeyDown(S):
    dx -= forwardX
    dz -= forwardZ
  if isKeyDown(A):
    dx -= rightX
    dz -= rightZ
  if isKeyDown(D):
    dx += rightX
    dz += rightZ

  # Normaliza o movimento horizontal
  let len = sqrt(dx*dx + dz*dz)
  if len > 0.001'f32:
    camera.position.x += (dx / len) * MoveSpeed * dt
    camera.position.z += (dz / len) * MoveSpeed * dt

  # 3. Pulo e Gravidade
  if not isGrounded:
    velY -= Gravity * dt

  if isGrounded and isKeyPressed(Space):
    velY = JumpForce
    isGrounded = false

  camera.position.y += velY * dt

  # Colisão com o chão (altura constante)
  if camera.position.y <= EyeHeight:
    camera.position.y = EyeHeight
    velY = 0.0'f32
    isGrounded = true

  # 4. Atualiza o alvo (target) da câmera baseado na posição e nos ângulos de visão
  let targetDirX = sin(cameraAngleX) * cos(cameraAngleY)
  let targetDirY = sin(cameraAngleY)
  let targetDirZ = -cos(cameraAngleX) * cos(cameraAngleY)

  camera.target.x = camera.position.x + targetDirX
  camera.target.y = camera.position.y + targetDirY
  camera.target.z = camera.position.z + targetDirZ

  # 5. Desenho
  drawing:
    clearBackground(RayWhite)
    
    mode3D(camera):
      # Chão (grade)
      drawGrid(20, 1.0'f32)
      
      # Cubo no centro
      drawCube(Vector3(x: 0.0'f32, y: 1.0'f32, z: 0.0'f32), 2.0'f32, 2.0'f32, 2.0'f32, Red)
      drawCubeWires(Vector3(x: 0.0'f32, y: 1.0'f32, z: 0.0'f32), 2.0'f32, 2.0'f32, 2.0'f32, Maroon)
      
      # Esfera à direita
      drawSphere(Vector3(x: 4.0'f32, y: 1.0'f32, z: 0.0'f32), 1.0'f32, Blue)
      
      # Cilindro à esquerda
      drawCylinder(Vector3(x: -4.0'f32, y: 1.0'f32, z: 0.0'f32), 1.0'f32, 1.0'f32, 2.0'f32, 16, Green)
      
    # Interface 2D
    drawText("Controles:", 10, 10, 20, DarkGray)
    drawText("- WASD para se mover", 10, 35, 18, Gray)
    drawText("- Mouse para olhar ao redor", 10, 55, 18, Gray)
    drawText("- ESPAÇO para pular", 10, 75, 18, Gray)

closeWindow()
