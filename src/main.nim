import raylib, raymath, ./admob
import std/math
import std/strformat

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

# Função para obter a cor base com base na altura (gradiente suave)
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

# Interpolação linear de cores para o céu
proc lerpColor(c1, c2: Color, t: float32): Color =
  let r = uint8(float32(c1.r) + (float32(c2.r) - float32(c1.r)) * t)
  let g = uint8(float32(c1.g) + (float32(c2.g) - float32(c1.g)) * t)
  let b = uint8(float32(c1.b) + (float32(c2.b) - float32(c1.b)) * t)
  return Color(r: r, g: g, b: b, a: 255)

# Cor do céu baseada na hora do dia (0.0 a 24.0)
proc getSkyColor(time: float32): Color =
  if time < 5.0'f32:
    let t = time / 5.0'f32
    return lerpColor(Color(r: 5, g: 5, b: 20, a: 255), Color(r: 20, g: 15, b: 40, a: 255), t)
  elif time < 6.5'f32:
    let t = (time - 5.0'f32) / 1.5'f32
    return lerpColor(Color(r: 20, g: 15, b: 40, a: 255), Color(r: 230, g: 120, b: 80, a: 255), t)
  elif time < 8.0'f32:
    let t = (time - 6.5'f32) / 1.5'f32
    return lerpColor(Color(r: 230, g: 120, b: 80, a: 255), Color(r: 100, g: 180, b: 240, a: 255), t)
  elif time < 16.0'f32:
    let t = (time - 8.0'f32) / 8.0'f32
    return lerpColor(Color(r: 100, g: 180, b: 240, a: 255), Color(r: 135, g: 206, b: 250, a: 255), t)
  elif time < 18.0'f32:
    let t = (time - 16.0'f32) / 2.0'f32
    return lerpColor(Color(r: 135, g: 206, b: 250, a: 255), Color(r: 220, g: 140, b: 70, a: 255), t)
  elif time < 19.5'f32:
    let t = (time - 18.0'f32) / 1.5'f32
    return lerpColor(Color(r: 220, g: 140, b: 70, a: 255), Color(r: 120, g: 50, b: 100, a: 255), t)
  elif time < 21.0'f32:
    let t = (time - 19.5'f32) / 1.5'f32
    return lerpColor(Color(r: 120, g: 50, b: 100, a: 255), Color(r: 25, g: 25, b: 60, a: 255), t)
  else:
    let t = (time - 21.0'f32) / 3.0'f32
    return lerpColor(Color(r: 25, g: 25, b: 60, a: 255), Color(r: 5, g: 5, b: 20, a: 255), t)

# Multiplicador de iluminação do terreno baseada na hora do dia (0.15 a 1.0)
proc getLightMultiplier(time: float32): float32 =
  if time >= 7.0'f32 and time <= 17.0'f32:
    return 1.0'f32
  elif time < 4.0'f32 or time > 20.0'f32:
    return 0.15'f32 # Noite escura, mas visível
  elif time >= 4.0'f32 and time < 7.0'f32:
    # Amanhecer
    let t = (time - 4.0'f32) / 3.0'f32
    return 0.15'f32 + t * 0.85'f32
  else:
    # Anoitecer
    let t = (time - 17.0'f32) / 3.0'f32
    return 1.0'f32 - t * 0.85'f32

# Inicialização do jogo
setTraceLogLevel(None)
setConfigFlags(flags(WindowResizable, Msaa4xHint, VsyncHint))
initWindow(800, 600, "Cenário 3D - Terra Procedimental Infinita")
setTargetFPS(60)
disableCursor()

# Configurações do jogador / câmera
const
  MouseSensitivity = 0.003'f32
  MoveSpeed = 12.0'f32
  Gravity = 22.0'f32
  JumpForce = 8.5'f32
  EyeHeight = 1.8'f32
  ViewDistance = 400.0'f32
  Step = 5.0'f32

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
  timeOfDay = 12.0'f32 # Começa ao meio-dia

while not windowShouldClose():
  let dt = getFrameTime()

  # Progresso do tempo: 24 horas passam em 10 minutos (600 segundos)
  # Taxa: 24.0 / 600.0 = 0.04 horas de jogo por segundo real
  timeOfDay += dt * 0.04'f32
  if timeOfDay >= 24.0'f32:
    timeOfDay -= 24.0'f32

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
    # Acompanha o relevo instantaneamente
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
    let skyColor = getSkyColor(timeOfDay)
    let lightMult = getLightMultiplier(timeOfDay)
    
    clearBackground(skyColor)
    
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
          
          # --- Simple Frustum / FOV Culling ---
          let centerX = x0 + Step * 0.5'f32
          let centerZ = z0 + Step * 0.5'f32
          let centerY = getHeight(centerX, centerZ)
          
          let toCellX = centerX - camera.position.x
          let toCellY = centerY - camera.position.y
          let toCellZ = centerZ - camera.position.z
          let distSq = toCellX*toCellX + toCellY*toCellY + toCellZ*toCellZ
          
          # Se estiver longe, verifica se está dentro do cone de visão da câmera
          if distSq > 15.0'f32 * 15.0'f32:
            let dist = sqrt(distSq)
            let cosAngle = (toCellX * targetDirX + toCellY * targetDirY + toCellZ * targetDirZ) / dist
            if cosAngle < 0.5'f32:
              continue
          
          let y00 = getHeight(x0, z0)
          let y10 = getHeight(x1, z0)
          let y01 = getHeight(x0, z1)
          let y11 = getHeight(x1, z1)
          
          let v00 = Vector3(x: x0, y: y00, z: z0)
          let v10 = Vector3(x: x1, y: y10, z: z0)
          let v01 = Vector3(x: x0, y: y01, z: z1)
          let v11 = Vector3(x: x1, y: y11, z: z1)
          
          # Cores baseadas na altura média de cada triângulo e atenuadas pela luz do dia
          let baseC1 = getColorForHeight((y00 + y10 + y01) / 3.0'f32)
          let baseC2 = getColorForHeight((y10 + y11 + y01) / 3.0'f32)
          
          let c1 = Color(
            r: uint8(float32(baseC1.r) * lightMult),
            g: uint8(float32(baseC1.g) * lightMult),
            b: uint8(float32(baseC1.b) * lightMult),
            a: 255
          )
          let c2 = Color(
            r: uint8(float32(baseC2.r) * lightMult),
            g: uint8(float32(baseC2.g) * lightMult),
            b: uint8(float32(baseC2.b) * lightMult),
            a: 255
          )
          
          drawTriangle3D(v00, v01, v10, c1)
          drawTriangle3D(v10, v01, v11, c2)

    # Interface 2D: Exibe a hora formatada no canto superior direito
    let hours = int(timeOfDay)
    let minutes = int((timeOfDay - float32(hours)) * 60.0'f32)
    let timeStr = fmt"{hours:02}:{minutes:02}"
    
    let screenWidth = getScreenWidth()
    let text = timeStr
    let fontSize = 24.int32
    let textWidth = measureText(text, fontSize)
    let posX = screenWidth - textWidth - 20
    let posY = 20.int32
    
    # Caixinha preta translúcida de fundo para legibilidade
    drawRectangle(posX - 10, posY - 5, textWidth + 20, fontSize + 10, Color(r: 0, g: 0, b: 0, a: 150))
    drawText(text, posX, posY, fontSize, RayWhite)

closeWindow()
