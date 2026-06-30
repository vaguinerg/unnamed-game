import raylib, raymath, ./admob
import std/math

when not defined(android):
  import std/os
  setCurrentDir getAppDir()

# Função de altura procedimental (combinação de senos/cossenos)
proc getHeight(x, z: float32): float32 =
  # Grandes elevações (montanhas)
  var h = sin(x * 0.015'f32) * cos(z * 0.015'f32) * 8.0'f32
  # Colinas médias
  h += sin(x * 0.05'f32) * sin(z * 0.05'f32) * 3.0'f32
  # Pequenos relevos (detalhes do chão)
  h += cos(x * 0.15'f32) * cos(z * 0.15'f32) * 0.8'f32
  return h

# Função para obter a cor com base na altura (gradiente suave)
proc getColorForHeight(y: float32): Color =
  if y < -3.0'f32:
    return Color(r: 35, g: 90, b: 35, a: 255) # Verde escuro (vales)
  elif y < 2.0'f32:
    let t = (y - (-3.0'f32)) / 5.0'f32
    let r = uint8(35.0'f32 + t * 45.0'f32)
    let g = uint8(90.0'f32 + t * 70.0'f32)
    let b = uint8(35.0'f32 + t * 25.0'f32)
    return Color(r: r, g: g, b: b, a: 255)
  elif y < 5.0'f32:
    let t = (y - 2.0'f32) / 3.0'f32
    let r = uint8(80.0'f32 + t * 50.0'f32)
    let g = uint8(160.0'f32 - t * 60.0'f32)
    let b = uint8(60.0'f32 + t * 10.0'f32)
    return Color(r: r, g: g, b: b, a: 255)
  elif y < 8.0'f32:
    let t = (y - 5.0'f32) / 3.0'f32
    let r = uint8(130.0'f32 - t * 50.0'f32)
    let g = uint8(100.0'f32 - t * 20.0'f32)
    let b = uint8(70.0'f32 + t * 10.0'f32)
    return Color(r: r, g: g, b: b, a: 255)
  else:
    let t = clamp((y - 8.0'f32) / 3.0'f32, 0.0'f32, 1.0'f32)
    let r = uint8(80.0'f32 + t * 165.0'f32)
    let g = uint8(80.0'f32 + t * 165.0'f32)
    let b = uint8(80.0'f32 + t * 165.0'f32)
    return Color(r: r, g: g, b: b, a: 255)

# Inicialização do jogo
setTraceLogLevel(None)
setConfigFlags(flags(WindowResizable, Msaa4xHint, VsyncHint))
initWindow(800, 600, "Cenário 3D - Terra Procedimental Infinita")
setTargetFPS(60)
disableCursor()

# Configurações do jogador / câmera
const
  MouseSensitivity = 0.003'f32
  MoveSpeed = 12.0'f32 # Velocidade para explorar melhor o terreno infinito
  Gravity = 22.0'f32
  JumpForce = 8.5'f32
  EyeHeight = 1.8'f32
  ViewDistance = 100.0'f32
  Step = 2.5'f32

let startHeight = getHeight(0.0'f32, 0.0'f32)
var
  camera = Camera(
    position: Vector3(x: 0.0'f32, y: startHeight + EyeHeight, z: 0.0'f32),
    target: Vector3(x: 0.0'f32, y: startHeight + EyeHeight, z: -1.0'f32),
    up: Vector3(x: 0.0'f32, y: 1.0'f32, z: 0.0'f32),
    fovy: 60.0'f32,
    projection: Perspective
  )
  cameraAngleX = 0.0'f32
  cameraAngleY = 0.0'f32
  velY = 0.0'f32
  isGrounded = true

while not windowShouldClose():
  let dt = getFrameTime()

  # 1. Controle da Câmera (Mouse)
  let mouseDelta = getMouseDelta()
  cameraAngleX += mouseDelta.x * MouseSensitivity
  cameraAngleY -= mouseDelta.y * MouseSensitivity
  cameraAngleY = clamp(cameraAngleY, -1.5'f32, 1.5'f32)

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

  let len = sqrt(dx*dx + dz*dz)
  if len > 0.001'f32:
    camera.position.x += (dx / len) * MoveSpeed * dt
    camera.position.z += (dz / len) * MoveSpeed * dt

  # 3. Gravidade e Pulo sobre o Terreno
  let groundHeight = getHeight(camera.position.x, camera.position.z)

  if not isGrounded:
    velY -= Gravity * dt
    camera.position.y += velY * dt

    # Colisão com o terreno dinâmico (aterrissagem)
    if camera.position.y <= groundHeight + EyeHeight:
      camera.position.y = groundHeight + EyeHeight
      velY = 0.0'f32
      isGrounded = true
  else:
    # Se está no chão, acompanha o relevo instantaneamente (subidas e descidas)
    camera.position.y = groundHeight + EyeHeight
    
    if isKeyPressed(Space):
      velY = JumpForce
      isGrounded = false

  # 4. Atualiza o alvo (target)
  let targetDirX = sin(cameraAngleX) * cos(cameraAngleY)
  let targetDirY = sin(cameraAngleY)
  let targetDirZ = -cos(cameraAngleX) * cos(cameraAngleY)

  camera.target.x = camera.position.x + targetDirX
  camera.target.y = camera.position.y + targetDirY
  camera.target.z = camera.position.z + targetDirZ

  # 5. Desenho do cenário
  drawing:
    clearBackground(SkyBlue)
    
    mode3D(camera):
      # Desenha a malha do terreno ao redor do jogador
      let gridCenterX = round(camera.position.x / Step) * Step
      let gridCenterZ = round(camera.position.z / Step) * Step
      let halfCells = int(ViewDistance / Step)

      for cz in -halfCells .. halfCells:
        for cx in -halfCells .. halfCells:
          let x0 = gridCenterX + float32(cx) * Step
          let x1 = x0 + Step
          let z0 = gridCenterZ + float32(cz) * Step
          let z1 = z0 + Step
          
          let y00 = getHeight(x0, z0)
          let y10 = getHeight(x1, z0)
          let y01 = getHeight(x0, z1)
          let y11 = getHeight(x1, z1)
          
          let v00 = Vector3(x: x0, y: y00, z: z0)
          let v10 = Vector3(x: x1, y: y10, z: z0)
          let v01 = Vector3(x: x0, y: y01, z: z1)
          let v11 = Vector3(x: x1, y: y11, z: z1)
          
          # Cores baseadas na altura média de cada triângulo
          let c1 = getColorForHeight((y00 + y10 + y01) / 3.0'f32)
          let c2 = getColorForHeight((y10 + y11 + y01) / 3.0'f32)
          
          drawTriangle3D(v00, v01, v10, c1)
          drawTriangle3D(v10, v01, v11, c2)

    # Interface 2D
    drawText("Terreno Procedimental Infinito", 10, 10, 20, DarkGray)
    drawText("Posicao X: " & $round(camera.position.x) & " Z: " & $round(camera.position.z), 10, 35, 18, Gray)
    drawText("- WASD para caminhar", 10, 60, 18, Gray)
    drawText("- Mouse para olhar", 10, 80, 18, Gray)
    drawText("- ESPACO para pular", 10, 100, 18, Gray)

closeWindow()
