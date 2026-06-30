import raylib, raymath, raygui, ./admob
import std/math
import std/strformat

when not defined(android):
  import std/os
  setCurrentDir getAppDir()

type
  GameState = enum
    StateMainMenu,
    StateOptionsMenu,
    StatePlaying

# --- Variáveis Globais do Vulto de Terror ---
var
  gameRandState: uint32 = 987654
  vultoAtivo: bool = false
  vultoPos: Vector3
  vultoStartPos: Vector3
  vultoEndPos: Vector3
  vultoProgress: float32 = 0.0'f32
  vultoSpeed: float32 = 0.0'f32
  vultoTimer: float32 = 5.0'f32 # Primeiro vulto após 5 segundos

proc gameRand(): float32 =
  gameRandState = gameRandState * 1664525 + 1013904223
  return float32(gameRandState and 0xFFFFFF) / 16777216.0'f32

# --- Gerador Aleatório Determinístico para Células (PRNG) ---
type
  CellRand = object
    state: uint32

proc initRand(x, z: int): CellRand =
  var s = uint32((x * 73856093) xor (z * 19349663))
  if s == 0: s = 1
  return CellRand(state: s)

proc nextFloat(r: var CellRand): float32 =
  r.state = r.state * 1664525 + 1013904223
  return float32(r.state and 0xFFFFFF) / 16777216.0'f32

const Step = 5.0'f32

# Função de altura procedimental (combinação de senos/cossenos)
proc getHeight(x, z: float32): float32 =
  # Grandes elevações (montanhas)
  var h = sin(x * 0.015'f32) * cos(z * 0.015'f32) * 8.0'f32
  # Colinas médias
  h += sin(x * 0.05'f32) * sin(z * 0.05'f32) * 3.0'f32
  # Pequenos relevos (detalhes do chão)
  h += cos(x * 0.15'f32) * cos(z * 0.15'f32) * 0.8'f32
  return h

# Função para obter a altura exata da malha triangular do terreno na coordenada (x, z)
# Isso evita que o jogador, câmera e árvores flutuem ou afundem nas colinas
proc getTerrainHeight(x, z: float32): float32 =
  let x0 = floor(x / Step) * Step
  let z0 = floor(z / Step) * Step
  let x1 = x0 + Step
  let z1 = z0 + Step
  
  let y00 = getHeight(x0, z0)
  let y10 = getHeight(x1, z0)
  let y01 = getHeight(x0, z1)
  let y11 = getHeight(x1, z1)
  
  let dx = (x - x0) / Step
  let dz = (z - z0) / Step
  
  if dx + dz < 1.0'f32:
    # Triângulo 1 (superior esquerdo)
    return y00 + dx * (y10 - y00) + dz * (y01 - y00)
  else:
    # Triângulo 2 (inferior direito)
    return y11 + (1.0'f32 - dx) * (y01 - y11) + (1.0'f32 - dz) * (y10 - y11)

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

# --- Função para desenhar as Árvores Procedimentais ---
proc drawTrees(camera: Camera, targetDirX, targetDirY, targetDirZ: float32, lightMult: float32, flashlightOn: bool) =
  const
    TreeCellSize = 40.0'f32 # Células maiores = menor densidade de árvores
    TreeDensity = 0.20'f32  # 20% de chance de ter uma árvore por célula
    ViewDist = 350.0'f32    # Alcance visual das árvores
    
    # Parâmetros da Lanterna
    FlashlightRange = 75.0'f32
    FlashlightConeCos = 0.96'f32
    FlashlightIntensity = 1.5'f32

  let gridCenterX = round(camera.position.x / TreeCellSize)
  let gridCenterZ = round(camera.position.z / TreeCellSize)
  let halfCells = int(ViewDist / TreeCellSize)

  for cz in -halfCells .. halfCells:
    for cx in -halfCells .. halfCells:
      let cellX = int(gridCenterX) + cx
      let cellZ = int(gridCenterZ) + cz

      var r = initRand(cellX, cellZ)

      if r.nextFloat() < TreeDensity:
        let offsetX = r.nextFloat() * TreeCellSize
        let offsetZ = r.nextFloat() * TreeCellSize
        let treeX = float32(cellX) * TreeCellSize + offsetX
        let treeZ = float32(cellZ) * TreeCellSize + offsetZ

        let toTreeX = treeX - camera.position.x
        let toTreeZ = treeZ - camera.position.z
        let distSq = toTreeX*toTreeX + toTreeZ*toTreeZ

        if distSq < ViewDist * ViewDist:
          if distSq > 20.0'f32 * 20.0'f32:
            let dist = sqrt(distSq)
            let cosAngle = (toTreeX * targetDirX + toTreeZ * targetDirZ) / dist
            if cosAngle < 0.5'f32:
              continue

          let treeY = getTerrainHeight(treeX, treeZ)
          # Apenas desenha árvores nas áreas verdes (abaixo das montanhas)
          if treeY >= 2.5'f32:
            continue

          let trunkHeight = 4.0'f32 + r.nextFloat() * 4.0'f32
          let trunkRadius = 0.25'f32 + r.nextFloat() * 0.2'f32
          
          var treeLight = lightMult
          if flashlightOn and distSq < FlashlightRange * FlashlightRange:
            let dist = sqrt(distSq)
            let normX = toTreeX / dist
            let normY = (treeY + trunkHeight / 2.0'f32 - camera.position.y) / dist
            let normZ = toTreeZ / dist
            let cosSpot = normX * targetDirX + normY * targetDirY + normZ * targetDirZ
            
            if cosSpot > FlashlightConeCos:
              let angleFactor = (cosSpot - FlashlightConeCos) / (1.0'f32 - FlashlightConeCos)
              let distFactor = 1.0'f32 - (dist / FlashlightRange)
              treeLight = clamp(treeLight + angleFactor * distFactor * FlashlightIntensity, 0.0'f32, 2.0'f32)

          let trunkPos = Vector3(x: treeX, y: treeY, z: treeZ)
          let trunkColor = Color(
            r: uint8(min(float32(DarkBrown.r) * treeLight, 255.0'f32)),
            g: uint8(min(float32(DarkBrown.g) * treeLight, 255.0'f32)),
            b: uint8(min(float32(DarkBrown.b) * treeLight, 255.0'f32)),
            a: 255
          )
          drawCylinder(trunkPos, trunkRadius, trunkRadius, trunkHeight, 6, trunkColor)

          let leafCount = 3 + int(r.nextFloat() * 4.0'f32)
          for i in 0 ..< leafCount:
            let leafOffset = Vector3(
              x: (r.nextFloat() - 0.5'f32) * (trunkRadius * 3.5'f32),
              y: trunkHeight + (r.nextFloat() - 0.1'f32) * 1.8'f32,
              z: (r.nextFloat() - 0.5'f32) * (trunkRadius * 3.5'f32)
            )
            let leafRadius = 1.0'f32 + r.nextFloat() * 1.2'f32
            let leafPos = Vector3(
              x: treeX + leafOffset.x,
              y: treeY + leafOffset.y,
              z: treeZ + leafOffset.z
            )

            let greenVal = uint8(90 + int(r.nextFloat() * 70.0'f32))
            let leafColor = Color(
              r: uint8(min(30.0'f32 * treeLight, 255.0'f32)),
              g: uint8(min(float32(greenVal) * treeLight, 255.0'f32)),
              b: uint8(min(30.0'f32 * treeLight, 255.0'f32)),
              a: 255
            )

            drawSphere(leafPos, leafRadius, leafColor)

# --- Função para disparar o evento do Vulto de Terror ---
proc dispararVultoDeTerror(camera: Camera, targetDirX, targetDirY, targetDirZ: float32) =
  const
    TreeCellSize = 40.0'f32
    TreeDensity = 0.20'f32
    ViewDist = 350.0'f32
    
    # Parâmetro do meio-termo
    TargetMidDist = 140.0'f32

  let gridCenterX = round(camera.position.x / TreeCellSize)
  let gridCenterZ = round(camera.position.z / TreeCellSize)
  let halfCells = int(ViewDist / TreeCellSize)

  var bestTreeX = 0.0'f32
  var bestTreeZ = 0.0'f32
  var minDiff = 999999.0'f32
  var foundStart = false

  # 1. Encontra a árvore visível mais próxima da distância do meio-termo (140 unidades)
  for cz in -halfCells .. halfCells:
    for cx in -halfCells .. halfCells:
      let cellX = int(gridCenterX) + cx
      let cellZ = int(gridCenterZ) + cz

      var r = initRand(cellX, cellZ)
      if r.nextFloat() < TreeDensity:
        let offsetX = r.nextFloat() * TreeCellSize
        let offsetZ = r.nextFloat() * TreeCellSize
        let treeX = float32(cellX) * TreeCellSize + offsetX
        let treeZ = float32(cellZ) * TreeCellSize + offsetZ

        let treeY = getTerrainHeight(treeX, treeZ)
        if treeY >= 2.5'f32:
          continue

        let toTreeX = treeX - camera.position.x
        let toTreeZ = treeZ - camera.position.z
        let distSq = toTreeX*toTreeX + toTreeZ*toTreeZ

        if distSq < ViewDist * ViewDist:
          let dist = sqrt(distSq)
          let cosAngle = (toTreeX * targetDirX + toTreeZ * targetDirZ) / dist
          if cosAngle >= 0.5'f32: # Visível na tela
            let diff = abs(dist - TargetMidDist)
            if diff < minDiff:
              minDiff = diff
              bestTreeX = treeX
              bestTreeZ = treeZ
              foundStart = true

  if not foundStart:
    return

  # 2. Encontra a árvore vizinha mais próxima
  var nearestTreeX = 0.0'f32
  var nearestTreeZ = 0.0'f32
  var minDistSq = 999999.0'f32
  var foundEnd = false

  let startCellX = round(bestTreeX / TreeCellSize)
  let startCellZ = round(bestTreeZ / TreeCellSize)

  for cz in -3 .. 3:
    for cx in -3 .. 3:
      if cx == 0 and cz == 0: continue
      let cellX = int(startCellX) + cx
      let cellZ = int(startCellZ) + cz

      var r = initRand(cellX, cellZ)
      if r.nextFloat() < TreeDensity:
        let offsetX = r.nextFloat() * TreeCellSize
        let offsetZ = r.nextFloat() * TreeCellSize
        let treeX = float32(cellX) * TreeCellSize + offsetX
        let treeZ = float32(cellZ) * TreeCellSize + offsetZ

        let treeY = getTerrainHeight(treeX, treeZ)
        if treeY >= 2.5'f32:
          continue

        let dx = treeX - bestTreeX
        let dz = treeZ - bestTreeZ
        let distSq = dx*dx + dz*dz

        if distSq > 1.0'f32 and distSq < minDistSq:
          minDistSq = distSq
          nearestTreeX = treeX
          nearestTreeZ = treeZ
          foundEnd = true

  if foundEnd:
    # 3. Inicia a corrida do vulto
    vultoStartPos = Vector3(x: bestTreeX, y: getTerrainHeight(bestTreeX, bestTreeZ), z: bestTreeZ)
    vultoEndPos = Vector3(x: nearestTreeX, y: getTerrainHeight(nearestTreeX, nearestTreeZ), z: nearestTreeZ)
    vultoPos = vultoStartPos
    vultoProgress = 0.0'f32
    
    let pathDist = sqrt(minDistSq)
    # Velocidade de corrida: 12.0 unidades por segundo (mais visível e natural)
    vultoSpeed = 12.0'f32 / pathDist
    vultoAtivo = true

# Inicialização do jogo
setTraceLogLevel(None)
setConfigFlags(flags(WindowResizable, Msaa4xHint, VsyncHint))
initWindow(800, 600, "Dark Rogue")
setTargetFPS(60)
setExitKey(Null) # Impede que a tecla ESC feche a janela automaticamente

# Configurações do jogador / câmera
const
  Gravity = 22.0'f32
  JumpForce = 8.5'f32
  EyeHeight = 1.8'f32
  ViewDistance = 400.0'f32

  # Parâmetros da Lanterna
  FlashlightRange = 75.0'f32
  FlashlightConeCos = 0.96'f32  # Abertura do cone da lanterna (~16 graus)
  FlashlightIntensity = 1.5'f32 # Intensidade máxima do brilho da lanterna

let startHeight = getTerrainHeight(0.0'f32, 0.0'f32)
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
  timeOfDay = 12.0'f32       # Começa ao meio-dia
  flashlightOn = false       # Estado da lanterna
  flashlightBattery = 1.0'f32 # Bateria da lanterna (0.0 a 1.0)
  stamina = 1.0'f32           # Energia para correr (0.0 a 1.0)

  # Configurações dinâmicas de menu
  gameState = StateMainMenu
  isFullscreenState = false
  mouseSensitivity = 0.003'f32
  shouldExit = false

while not windowShouldClose() and not shouldExit:
  let dt = getFrameTime()

  # Progresso do tempo: 24 horas passam em 10 minutos (600 segundos)
  # Taxa: 24.0 / 600.0 = 0.04 horas de jogo por segundo real
  timeOfDay += dt * 0.04'f32
  if timeOfDay >= 24.0'f32:
    timeOfDay -= 24.0'f32

  # Lógica do Vulto de Terror
  if gameState == StatePlaying:
    if not vultoAtivo:
      vultoTimer -= dt
      if vultoTimer <= 0.0'f32:
        # Mira aproximada da câmera
        let tDirX = sin(cameraAngleX) * cos(cameraAngleY)
        let tDirY = sin(cameraAngleY)
        let tDirZ = -cos(cameraAngleX) * cos(cameraAngleY)
        dispararVultoDeTerror(camera, tDirX, tDirY, tDirZ)
        # Próximo vulto em 5 segundos fixos
        vultoTimer = 5.0'f32
    else:
      # Progresso da corrida do vulto
      vultoProgress += dt * vultoSpeed
      if vultoProgress >= 1.0'f32:
        vultoAtivo = false
      else:
        let t = vultoProgress
        let cx = vultoStartPos.x + (vultoEndPos.x - vultoStartPos.x) * t
        let cz = vultoStartPos.z + (vultoEndPos.z - vultoStartPos.z) * t
        let cy = getTerrainHeight(cx, cz)
        vultoPos = Vector3(x: cx, y: cy, z: cz)

  # Lógica de estados do jogo
  if gameState == StatePlaying:
    # Retorna ao menu ao pressionar ESC (pausa)
    if isKeyPressed(Escape):
      gameState = StateMainMenu
      enableCursor()

    # Lógica de controle e bateria da Lanterna
    if isKeyPressed(F):
      if flashlightBattery > 0.0'f32 or not flashlightOn:
        flashlightOn = not flashlightOn

    if flashlightOn:
      flashlightBattery -= dt * 0.1'f32
      if flashlightBattery <= 0.0'f32:
        flashlightBattery = 0.0'f32
        flashlightOn = false
    else:
      if flashlightBattery < 1.0'f32:
        flashlightBattery += dt * 0.1'f32
        if flashlightBattery > 1.0'f32:
          flashlightBattery = 1.0'f32

    # 1. Controle da Câmera (Mouse)
    let mouseDelta = getMouseDelta()
    cameraAngleX += mouseDelta.x * mouseSensitivity
    cameraAngleY -= mouseDelta.y * mouseSensitivity
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
    let isMoving = len > 0.001'f32
    let wantSprint = isKeyDown(LeftShift) or isKeyDown(RightShift)
    let canSprint = wantSprint and isMoving and stamina > 0.0'f32
    
    let moveSpeed = if canSprint: 16.0'f32 else: 8.0'f32
    
    if canSprint:
      stamina -= dt * 0.2'f32 # Consome tudo em 5 segundos
      if stamina < 0.0'f32: stamina = 0.0'f32
    else:
      if stamina < 1.0'f32:
        stamina += dt * 0.2'f32 # Recarrega tudo em 5 segundos
        if stamina > 1.0'f32: stamina = 1.0'f32

    if isMoving:
      camera.position.x += (dx / len) * moveSpeed * dt
      camera.position.z += (dz / len) * moveSpeed * dt

    # --- Colisão do Jogador com as Árvores ---
    const
      TreeCellSize = 40.0'f32
      TreeDensity = 0.20'f32
      PlayerRadius = 0.4'f32

    let pCellX = round(camera.position.x / TreeCellSize)
    let pCellZ = round(camera.position.z / TreeCellSize)

    # Verifica a célula atual e as 8 vizinhas
    for cz in -1 .. 1:
      for cx in -1 .. 1:
        let cellX = int(pCellX) + cx
        let cellZ = int(pCellZ) + cz

        var r = initRand(cellX, cellZ)
        if r.nextFloat() < TreeDensity:
          # Gera a posição exata da árvore
          let offsetX = r.nextFloat() * TreeCellSize
          let offsetZ = r.nextFloat() * TreeCellSize
          let treeX = float32(cellX) * TreeCellSize + offsetX
          let treeZ = float32(cellZ) * TreeCellSize + offsetZ
          
          # Apenas processa colisão se a árvore puder crescer nesta altura (área verde)
          let treeY = getTerrainHeight(treeX, treeZ)
          if treeY >= 2.5'f32:
            continue

          let trunkRadius = 0.25'f32 + r.nextFloat() * 0.2'f32

          # Vetor da árvore até o jogador (2D)
          let toPlayerX = camera.position.x - treeX
          let toPlayerZ = camera.position.z - treeZ
          let distSq = toPlayerX*toPlayerX + toPlayerZ*toPlayerZ
          let minDist = PlayerRadius + trunkRadius

          # Se houver colisão, empurra o jogador para fora
          if distSq < minDist * minDist:
            let dist = sqrt(distSq)
            if dist > 0.001'f32:
              let overlap = minDist - dist
              camera.position.x += (toPlayerX / dist) * overlap
              camera.position.z += (toPlayerZ / dist) * overlap

    # 3. Gravidade e Pulo sobre o Terreno
    let groundHeight = getTerrainHeight(camera.position.x, camera.position.z)

    if not isGrounded:
      velY -= Gravity * dt
      camera.position.y += velY * dt

      # Colisão com o terreno dinâmico (aterrissagem)
      if camera.position.y <= groundHeight + EyeHeight:
        camera.position.y = groundHeight + EyeHeight
        velY = 0.0'f32
        isGrounded = true
    else:
      # Acompanha o relevo
      camera.position.y = groundHeight + EyeHeight
      
      if isKeyPressed(Space):
        velY = JumpForce
        isGrounded = false

    # Atualiza o alvo (target) baseado na mira
    let targetDirX = sin(cameraAngleX) * cos(cameraAngleY)
    let targetDirY = sin(cameraAngleY)
    let targetDirZ = -cos(cameraAngleX) * cos(cameraAngleY)

    camera.target.x = camera.position.x + targetDirX
    camera.target.y = camera.position.y + targetDirY
    camera.target.z = camera.position.z + targetDirZ

  else:
    # Se pressionar ESC no menu, fecha o jogo; nas opções, volta para o menu principal
    if isKeyPressed(Escape):
      if gameState == StateOptionsMenu:
        gameState = StateMainMenu
      else:
        shouldExit = true

    # Modo de Menu: a câmera orbita lentamente ao redor do centro do mundo
    cameraAngleX += dt * 0.05'f32
    cameraAngleY = -0.2'f32
    
    let menuCamRadius = 40.0'f32
    camera.position.x = sin(cameraAngleX) * menuCamRadius
    camera.position.z = cos(cameraAngleX) * menuCamRadius
    camera.position.y = getTerrainHeight(camera.position.x, camera.position.z) + 10.0'f32
    
    # Mantém o alvo olhando para o centro da cena
    camera.target = Vector3(x: 0.0'f32, y: getTerrainHeight(0.0'f32, 0.0'f32), z: 0.0'f32)

  # Variáveis de mira usadas no cálculo da lanterna e culling
  let targetDirX = sin(cameraAngleX) * cos(cameraAngleY)
  let targetDirY = sin(cameraAngleY)
  let targetDirZ = -cos(cameraAngleX) * cos(cameraAngleY)

  # 5. Desenho do cenário
  drawing:
    let skyColor = getSkyColor(timeOfDay)
    let lightMult = getLightMultiplier(timeOfDay)
    
    clearBackground(skyColor)
    
    mode3D(camera):
      # Desenha a malha do terreno ao redor do jogador ou centro do menu
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

          # --- Cálculo do SpotLight da Lanterna ---
          var cellFlashlight = 0.0'f32
          if flashlightOn and distSq < FlashlightRange * FlashlightRange:
            let dist = sqrt(distSq)
            let normX = toCellX / dist
            let normY = toCellY / dist
            let normZ = toCellZ / dist
            
            let cosSpot = normX * targetDirX + normY * targetDirY + normZ * targetDirZ
            if cosSpot > FlashlightConeCos:
              let angleFactor = (cosSpot - FlashlightConeCos) / (1.0'f32 - FlashlightConeCos)
              let distFactor = 1.0'f32 - (dist / FlashlightRange)
              cellFlashlight = angleFactor * distFactor * FlashlightIntensity
          
          let y00 = getHeight(x0, z0)
          let y10 = getHeight(x1, z0)
          let y01 = getHeight(x0, z1)
          let y11 = getHeight(x1, z1)
          
          let v00 = Vector3(x: x0, y: y00, z: z0)
          let v10 = Vector3(x: x1, y: y10, z: z0)
          let v01 = Vector3(x: x0, y: y01, z: z1)
          let v11 = Vector3(x: x1, y: y11, z: z1)
          
          # Cores baseadas na altura média de cada triângulo e atenuadas pela luz do dia + lanterna
          let baseC1 = getColorForHeight((y00 + y10 + y01) / 3.0'f32)
          let baseC2 = getColorForHeight((y10 + y11 + y01) / 3.0'f32)
          
          let totalLight1 = clamp(lightMult + cellFlashlight, 0.0'f32, 2.0'f32)
          let totalLight2 = clamp(lightMult + cellFlashlight, 0.0'f32, 2.0'f32)
          
          let c1 = Color(
            r: uint8(min(float32(baseC1.r) * totalLight1, 255.0'f32)),
            g: uint8(min(float32(baseC1.g) * totalLight1, 255.0'f32)),
            b: uint8(min(float32(baseC1.b) * totalLight1, 255.0'f32)),
            a: 255
          )
          let c2 = Color(
            r: uint8(min(float32(baseC2.r) * totalLight2, 255.0'f32)),
            g: uint8(min(float32(baseC2.g) * totalLight2, 255.0'f32)),
            b: uint8(min(float32(baseC2.b) * totalLight2, 255.0'f32)),
            a: 255
          )
          
          drawTriangle3D(v00, v01, v10, c1)
          drawTriangle3D(v10, v01, v11, c2)

      # Desenha as árvores procedimentais dentro do modo 3D
      drawTrees(camera, targetDirX, targetDirY, targetDirZ, lightMult, flashlightOn)

      # Desenha o vulto se estiver ativo (silhueta preta pura)
      if vultoAtivo:
        drawCylinder(vultoPos, 0.25'f32, 0.25'f32, 1.8'f32, 6, Color(r: 0, g: 0, b: 0, a: 245))

    # UI 2D do Jogo
    let screenWidth = getScreenWidth().float32
    let screenHeight = getScreenHeight().float32

    if gameState == StateMainMenu:
      # --- MENU PRINCIPAL ---
      let title = "DARK ROGUE"
      let titleFontSize = 40.int32
      let titleWidth = measureText(title, titleFontSize).float32
      drawText(title, int32(screenWidth/2 - titleWidth/2), int32(screenHeight/2 - 150), titleFontSize, RayWhite)

      let btnWidth = 220.float32
      let btnHeight = 40.float32
      let btnX = screenWidth/2 - btnWidth/2

      if button(Rectangle(x: btnX, y: screenHeight/2 - 40, width: btnWidth, height: btnHeight), "Iniciar"):
        gameState = StatePlaying
        disableCursor()

      if button(Rectangle(x: btnX, y: screenHeight/2 + 20, width: btnWidth, height: btnHeight), "Opcoes"):
        gameState = StateOptionsMenu

      if button(Rectangle(x: btnX, y: screenHeight/2 + 80, width: btnWidth, height: btnHeight), "Sair"):
        shouldExit = true

    elif gameState == StateOptionsMenu:
      # --- MENU DE OPÇÕES ---
      let title = "OPCOES"
      let titleFontSize = 40.int32
      let titleWidth = measureText(title, titleFontSize).float32
      drawText(title, int32(screenWidth/2 - titleWidth/2), int32(screenHeight/2 - 150), titleFontSize, RayWhite)

      let optWidth = 220.float32
      let optHeight = 30.float32
      let optX = screenWidth/2 - optWidth/2

      # Checkbox de Tela Cheia
      if checkBox(Rectangle(x: optX, y: screenHeight/2 - 40, width: 20, height: 20), "Tela Cheia", isFullscreenState):
        toggleFullscreen()

      # Slider de Sensibilidade
      var sensValue = mouseSensitivity * 1000.0'f32
      if slider(Rectangle(x: optX, y: screenHeight/2, width: 150, height: 20), "Sensibilidade: ", fmt"{sensValue:.1f}", sensValue, 1.0'f32, 10.0'f32):
        mouseSensitivity = sensValue / 1000.0'f32

      # Botão Voltar
      if button(Rectangle(x: optX, y: screenHeight/2 + 60, width: optWidth, height: 40), "Voltar"):
        gameState = StateMainMenu

    else:
      # --- JOGO ATIVO (UI UNIFICADA DE STATUS) ---
      let hours = int(timeOfDay)
      let minutes = int((timeOfDay - float32(hours)) * 60.0'f32)
      let timeStr = fmt"{hours:02}:{minutes:02}"
      
      let hasFlashlight = flashlightBattery < 1.0'f32
      let hasStamina = stamina < 1.0'f32
      
      # Largura e posições
      let panelWidth = 240.float32
      let panelX = screenWidth - panelWidth - 20.float32
      let panelY = 20.float32
      
      # Altura dinâmica baseada na visibilidade dos elementos
      var panelHeight = 40.float32 # Apenas para o relógio
      if hasFlashlight: panelHeight += 30.float32
      if hasStamina: panelHeight += 30.float32
      
      # 1. Desenha o Painel de Status unificado do RayGui
      panel(Rectangle(x: panelX, y: panelY, width: panelWidth, height: panelHeight), "")
      
      # 2. Desenha o Relógio (usando o Label do RayGui)
      label(Rectangle(x: panelX + 15.float32, y: panelY + 10.float32, width: panelWidth - 30.float32, height: 20.float32), "Hora: " & timeStr)
      
      # 3. Desenha as barras de progresso (Lanterna e Energia) dentro do painel
      var elementY = panelY + 40.float32
      let pbWidth = 140.float32
      let pbHeight = 16.float32
      let pbX = panelX + 85.float32 # Dá espaço de 70px para o texto da label à esquerda
      
      if hasFlashlight:
        progressBar(Rectangle(x: pbX, y: elementY, width: pbWidth, height: pbHeight), "Lanterna", "", flashlightBattery, 0.0'f32, 1.0'f32)
        elementY += 30.float32
        
      if hasStamina:
        progressBar(Rectangle(x: pbX, y: elementY, width: pbWidth, height: pbHeight), "Energia", "", stamina, 0.0'f32, 1.0'f32)
        elementY += 30.float32

closeWindow()
