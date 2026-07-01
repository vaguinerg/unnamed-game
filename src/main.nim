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

  # Estrutura para partículas físicas de água (Splash)
  SplashParticle = object
    position: Vector3
    velocity: Vector3
    color: Color
    lifetime: float32
    maxLifetime: float32
    size: float32

# --- Código-fonte dos Shaders da Água (GLSL 330 Avançado) ---
const
  vsWaterCode = """
  #version 330
  in vec3 vertexPosition;
  in vec2 vertexTexcoord;
  in vec4 vertexColor;
  uniform mat4 mvp;
  out vec3 fragPosition;
  out vec2 fragTexCoord;
  out vec4 fragColor;
  void main()
  {
      fragPosition = vertexPosition;
      fragTexCoord = vertexTexcoord;
      fragColor = vertexColor;
      gl_Position = mvp * vec4(vertexPosition, 1.0);
  }
  """

  fsWaterCode = """
  #version 330
  in vec3 fragPosition;
  in vec2 fragTexCoord;
  in vec4 fragColor;
  out vec4 finalColor;
  uniform float uTime;
  uniform float uLightMult;
  uniform vec3 uCameraPos;
  uniform vec3 uFlashlightPos;
  uniform vec3 uFlashlightDir;
  uniform int uFlashlightOn;

  // Ruído Fracionário Browniano (fBm) para simulação de ondas complexas
  float hash(vec2 p) {
      return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
  }

  float noise(vec2 p) {
      vec2 i = floor(p);
      vec2 f = fract(p);
      vec2 u = f*f*(3.0-2.0*f);
      return mix(mix(hash(i + vec2(0.0,0.0)), hash(i + vec2(1.0,0.0)), u.x),
                 mix(hash(i + vec2(0.0,1.0)), hash(i + vec2(1.0,1.0)), u.x), u.y);
  }

  float fbm(vec2 p) {
      float v = 0.0;
      float a = 0.5;
      vec2 shift = vec2(100.0);
      mat2 rot = mat2(cos(0.5), sin(0.5), -sin(0.5), cos(0.5));
      for (int i = 0; i < 4; ++i) {
          v += a * noise(p);
          p = rot * p * 2.0 + shift;
          a *= 0.5;
      }
      return v;
  }

  void main()
  {
      // Duas camadas de ruído de onda se movendo em direções opostas
      vec2 uv1 = fragPosition.xz * 0.15 + vec2(uTime * 0.04, uTime * 0.02);
      vec2 uv2 = fragPosition.xz * 0.12 - vec2(uTime * 0.03, uTime * 0.05);
      
      float n1 = fbm(uv1);
      float n2 = fbm(uv2);
      float w = mix(n1, n2, 0.5);
      
      // Cálculo dinâmico do vetor normal perturbado pela altura da onda
      float eps = 0.1;
      float n_x = fbm(uv1 + vec2(eps, 0.0)) - fbm(uv1 - vec2(eps, 0.0));
      float n_z = fbm(uv1 + vec2(0.0, eps)) - fbm(uv1 - vec2(0.0, eps));
      vec3 normal = normalize(vec3(n_x * 2.0, 1.0, n_z * 2.0));
      
      // Degradê de cor da água (azul profundo a verde esmeralda translúcido)
      vec3 deepColor = vec3(0.01, 0.05, 0.18) * uLightMult;
      vec3 shallowColor = vec3(0.04, 0.28, 0.44) * uLightMult;
      vec3 waterBaseColor = mix(deepColor, shallowColor, w);
      
      // Espuma ou brilho nas cristas das ondas
      if (w > 0.68) {
          waterBaseColor += vec3(0.12, 0.22, 0.28) * (w - 0.68) * 5.0 * uLightMult;
      }
      
      // Efeito Fresnel avançado usando a normal perturbada pela onda
      vec3 viewDir = normalize(uCameraPos - fragPosition);
      float fresnel = pow(1.0 - max(dot(viewDir, normal), 0.0), 4.0);
      vec3 skyColor = vec3(0.12, 0.28, 0.45) * uLightMult;
      vec3 color = mix(waterBaseColor, skyColor, fresnel * 0.7);
      
      // Iluminação e reflexos especulares dinâmicos da Lanterna
      if (uFlashlightOn == 1) {
          vec3 lightDir = normalize(fragPosition - uFlashlightPos);
          float dist = length(fragPosition - uFlashlightPos);
          if (dist < 75.0) {
              float cosSpot = dot(lightDir, uFlashlightDir);
              if (cosSpot > 0.96) {
                  float angleFactor = (cosSpot - 0.96) / 0.04;
                  float distFactor = 1.0 - (dist / 75.0);
                  
                  // Blinn-Phong baseado na normal ondulada
                  vec3 halfDir = normalize(viewDir - lightDir);
                  float spec = pow(max(dot(normal, halfDir), 0.0), 64.0);
                  
                  color += vec3(0.4, 0.75, 1.0) * angleFactor * distFactor * (0.25 + spec * 1.5);
              }
          }
      }
      
      // Neblina (fog) de suspense integrada
      float distToCam = length(fragPosition - uCameraPos);
      float fogFactor = clamp((80.0 - distToCam) / 30.0, 0.0, 1.0);
      color = mix(skyColor, color, fogFactor);
      
      finalColor = vec4(color, 0.88);
  }
  """

# --- Variáveis Globais ---
var
  gameRandState: uint32 = 987654
  
  # Stalker (Vulto de Terror)
  stalkerAtivo: bool = false
  stalkerPos: Vector3
  stalkerStartPos: Vector3
  stalkerEndPos: Vector3
  stalkerProgress: float32 = 0.0'f32
  stalkerSpeed: float32 = 0.0'f32
  stalkerTimer: float32 = 5.0'f32
  stalkerLookTimer: float32 = 15.0'f32
  stalkerContagemRegressiva: float32 = 10.0'f32
  stalkerEmAlerta: bool = false
  isGameOver: bool = false

  # Shader e Partículas da Água
  waterShader: Shader
  particles: seq[SplashParticle] = @[]

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

# Resolução do terreno em 8x
const Step = 0.625'f32

# Geração de altura procedimental do mapa
proc getHeight(x, z: float32): float32 =
  var h = sin(x * 0.015'f32) * cos(z * 0.015'f32) * 8.0'f32
  h += sin(x * 0.05'f32) * sin(z * 0.05'f32) * 3.0'f32
  h += cos(x * 0.15'f32) * cos(z * 0.15'f32) * 0.8'f32
  return h

# Altura exata da malha triangular do terreno
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
    return y00 + dx * (y10 - y00) + dz * (y01 - y00)
  else:
    return y11 + (1.0'f32 - dx) * (y01 - y11) + (1.0'f32 - dz) * (y10 - y11)

# Cor base baseada na altura
proc getColorForHeight(y: float32): Color =
  if y < -3.0'f32:
    return Color(r: 25, g: 25, b: 20, a: 255) # Leito de rio lamacento
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

# Interpolação de cores para o céu
proc lerpColor(c1, c2: Color, t: float32): Color =
  let r = uint8(float32(c1.r) + (float32(c2.r) - float32(c1.r)) * t)
  let g = uint8(float32(c1.g) + (float32(c2.g) - float32(c1.g)) * t)
  let b = uint8(float32(c1.b) + (float32(c2.b) - float32(c1.b)) * t)
  return Color(r: r, g: g, b: b, a: 255)

# Cor do céu baseada no horário
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

# Intensidade de luz solar
proc getLightMultiplier(time: float32): float32 =
  if time >= 7.0'f32 and time <= 17.0'f32:
    return 1.0'f32
  elif time < 4.0'f32 or time > 20.0'f32:
    return 0.15'f32
  elif time >= 4.0'f32 and time < 7.0'f32:
    let t = (time - 4.0'f32) / 3.0'f32
    return 0.15'f32 + t * 0.85'f32
  else:
    let t = (time - 17.0'f32) / 3.0'f32
    return 1.0'f32 - t * 0.85'f32

# Desenha árvores procedimentais
proc drawTrees(camera: Camera, targetDirX, targetDirY, targetDirZ: float32, lightMult: float32, flashlightOn: bool, skyColor: Color) =
  const
    TreeCellSize = 20.0'f32
    TreeDensity = 0.15'f32
    ViewDist = 80.0'f32
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
          if distSq > 10.0'f32 * 10.0'f32:
            let dist = sqrt(distSq)
            let cosAngle = (toTreeX * targetDirX + toTreeZ * targetDirZ) / dist
            if cosAngle < 0.5'f32:
              continue

          let treeY = getTerrainHeight(treeX, treeZ)
          if treeY >= 2.5'f32 or treeY < -3.0'f32:
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

          let dist = sqrt(distSq)
          let fogFactor = clamp((80.0'f32 - dist) / 30.0'f32, 0.0'f32, 1.0'f32)
          let trunkColor_fog = lerpColor(skyColor, trunkColor, fogFactor)

          drawCylinder(trunkPos, trunkRadius, trunkRadius, trunkHeight, 6, trunkColor_fog)

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
            let leafColor_fog = lerpColor(skyColor, leafColor, fogFactor)

            drawSphere(leafPos, leafRadius, leafColor_fog)

# --- Inicializa o Stalker ---
proc iniciarStalker(camera: Camera) =
  const
    TreeCellSize = 20.0'f32
    TreeDensity = 0.15'f32
    ViewDist = 80.0'f32
    TargetDist = 40.0'f32

  let gridCenterX = round(camera.position.x / TreeCellSize)
  let gridCenterZ = round(camera.position.z / TreeCellSize)
  let halfCells = int(ViewDist / TreeCellSize)

  var bestTreeX = 0.0'f32
  var bestTreeZ = 0.0'f32
  var minDiff = 999999.0'f32
  var found = false

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
        if treeY >= 2.5'f32 or treeY < -3.0'f32:
          continue

        let dx = treeX - camera.position.x
        let dz = treeZ - camera.position.z
        let dist = sqrt(dx*dx + dz*dz)

        let diff = abs(dist - TargetDist)
        if diff < minDiff:
          minDiff = diff
          bestTreeX = treeX
          bestTreeZ = treeZ
          found = true

  if found:
    stalkerStartPos = Vector3(x: bestTreeX, y: getTerrainHeight(bestTreeX, bestTreeZ), z: bestTreeZ)
    stalkerEndPos = stalkerStartPos
    stalkerPos = stalkerStartPos
    stalkerProgress = 1.0'f32
    stalkerSpeed = 0.5'f32
    stalkerAtivo = true

# --- IA do Stalker ---
proc proximaArvoreStalker(camera: Camera, cameraAngleX, cameraAngleY: float32) =
  const
    TreeCellSize = 20.0'f32
    TreeDensity = 0.15'f32
    SearchRadius = 3
    MinDistToPlayer = 18.0'f32

  let startCellX = round(stalkerEndPos.x / TreeCellSize)
  let startCellZ = round(stalkerEndPos.z / TreeCellSize)

  let tDirX = sin(cameraAngleX) * cos(cameraAngleY)
  let tDirY = sin(cameraAngleY)
  let tDirZ = -cos(cameraAngleX) * cos(cameraAngleY)

  let dxCurr = stalkerEndPos.x - camera.position.x
  let dzCurr = stalkerEndPos.z - camera.position.z
  let distToPlayerCurrent = sqrt(dxCurr*dxCurr + dzCurr*dzCurr)

  var playerIsLookingAtCurrent = false
  if distToPlayerCurrent < 350.0'f32:
    let cosAngleCurrent = (dxCurr * tDirX + (stalkerEndPos.y - camera.position.y) * tDirY + dzCurr * tDirZ) / distToPlayerCurrent
    if cosAngleCurrent >= 0.5'f32:
      playerIsLookingAtCurrent = true

  var stealthyCandidates: seq[tuple[x, z: float32, distSq: float32]] = @[]
  var visibleCandidates: seq[tuple[x, z: float32, distSq: float32]] = @[]

  for cz in -SearchRadius .. SearchRadius:
    for cx in -SearchRadius .. SearchRadius:
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
        if treeY >= 2.5'f32 or treeY < -3.0'f32:
          continue

        let dxToCurrent = treeX - stalkerEndPos.x
        let dzToCurrent = treeZ - stalkerEndPos.z
        let stepDistSq = dxToCurrent*dxToCurrent + dzToCurrent*dzToCurrent

        let dxToPlayer = treeX - camera.position.x
        let dzToPlayer = treeZ - camera.position.z
        let distToPlayerNew = sqrt(dxToPlayer*dxToPlayer + dzToPlayer*dzToPlayer)

        if stepDistSq > 1.0'f32 and distToPlayerNew < distToPlayerCurrent - 2.0'f32 and distToPlayerNew >= MinDistToPlayer:
          let cosAngleNew = (dxToPlayer * tDirX + (treeY - camera.position.y) * tDirY + dzToPlayer * tDirZ) / distToPlayerNew
          
          if cosAngleNew < 0.45'f32:
            stealthyCandidates.add((treeX, treeZ, stepDistSq))
          else:
            visibleCandidates.add((treeX, treeZ, stepDistSq))

  var chosenX = 0.0'f32
  var chosenZ = 0.0'f32
  var found = false

  if stealthyCandidates.len > 0:
    var minDistSq = 999999.0'f32
    for cand in stealthyCandidates:
      if cand.distSq < minDistSq:
        minDistSq = cand.distSq
        chosenX = cand.x
        chosenZ = cand.z
        found = true
  else:
    if playerIsLookingAtCurrent:
      found = false
    else:
      var minDistSq = 999999.0'f32
      for cand in visibleCandidates:
        if cand.distSq < minDistSq:
          minDistSq = cand.distSq
          chosenX = cand.x
          chosenZ = cand.z
          found = true

  if found:
    stalkerStartPos = stalkerEndPos
    stalkerEndPos = Vector3(x: chosenX, y: getTerrainHeight(chosenX, chosenZ), z: chosenZ)
    stalkerProgress = 0.0'f32
    stalkerSpeed = 0.5'f32
  else:
    stalkerStartPos = stalkerEndPos
    stalkerProgress = 0.0'f32
    stalkerSpeed = 0.5'f32

proc jogadorEstaOlhandoStalker(camera: Camera, targetDir: Vector3, lightMult: float32, flashlightOn: bool): bool =
  let positions = [stalkerPos, stalkerEndPos]
  for P in positions:
    let toTargetX = P.x - camera.position.x
    let toTargetY = (P.y + 0.9'f32) - camera.position.y
    let toTargetZ = P.z - camera.position.z
    let distSq = toTargetX*toTargetX + toTargetY*toTargetY + toTargetZ*toTargetZ
    
    if distSq < 80.0'f32 * 80.0'f32:
      let dist = sqrt(distSq)
      let cosAngle = (toTargetX * targetDir.x + toTargetY * targetDir.y + toTargetZ * targetDir.z) / dist
      
      if cosAngle >= 0.82'f32:
        if lightMult >= 0.3'f32:
          return true
        elif flashlightOn and dist < 75.0'f32:
          let cosSpot = (toTargetX * targetDir.x + toTargetY * targetDir.y + toTargetZ * targetDir.z) / dist
          if cosSpot >= 0.96'f32:
            return true
  return false

# Inicialização do jogo
setTraceLogLevel(None)
setConfigFlags(flags(WindowResizable, Msaa4xHint, VsyncHint))
initWindow(800, 600, "Dark Rogue")
setTargetFPS(60)
setExitKey(Null)

waterShader = loadShaderFromMemory(vsWaterCode, fsWaterCode)

const
  Gravity = 22.0'f32
  JumpForce = 8.5'f32
  EyeHeight = 1.8'f32
  ViewDistance = 80.0'f32

  # Parâmetros da Lanterna
  FlashlightRange = 75.0'f32
  FlashlightConeCos = 0.96'f32
  FlashlightIntensity = 1.5'f32

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
  timeOfDay = 12.0'f32
  flashlightOn = false
  flashlightBattery = 1.0'f32
  stamina = 1.0'f32

  gameState = StateMainMenu
  isFullscreenState = false
  mouseSensitivity = 0.003'f32
  shouldExit = false

while not windowShouldClose() and not shouldExit:
  let dt = getFrameTime()

  timeOfDay += dt * 0.04'f32
  if timeOfDay >= 24.0'f32:
    timeOfDay -= 24.0'f32

  let targetDirX = sin(cameraAngleX) * cos(cameraAngleY)
  let targetDirY = sin(cameraAngleY)
  let targetDirZ = -cos(cameraAngleX) * cos(cameraAngleY)
  let targetDirVec = Vector3(x: targetDirX, y: targetDirY, z: targetDirZ)

  let lightMult = getLightMultiplier(timeOfDay)

  # Lógica do Stalker
  if gameState == StatePlaying and not isGameOver:
    let playerSeesStalker = jogadorEstaOlhandoStalker(camera, targetDirVec, lightMult, flashlightOn)

    if playerSeesStalker:
      stalkerLookTimer = 15.0'f32
      stalkerContagemRegressiva = 10.0'f32
      stalkerEmAlerta = false
    else:
      if not stalkerEmAlerta:
        stalkerLookTimer -= dt
        if stalkerLookTimer <= 0.0'f32:
          stalkerLookTimer = 0.0'f32
          stalkerEmAlerta = true
      else:
        stalkerContagemRegressiva -= dt
        if stalkerContagemRegressiva <= 0.0'f32:
          stalkerContagemRegressiva = 0.0'f32
          isGameOver = true
          enableCursor()

    if stalkerAtivo:
      stalkerProgress += dt * stalkerSpeed
      if stalkerProgress >= 1.0'f32:
        stalkerProgress = 1.0'f32
        stalkerPos = stalkerEndPos
        proximaArvoreStalker(camera, cameraAngleX, cameraAngleY)
      else:
        let t = stalkerProgress
        let cx = stalkerStartPos.x + (stalkerEndPos.x - stalkerStartPos.x) * t
        let cz = stalkerStartPos.z + (stalkerEndPos.z - stalkerStartPos.z) * t
        let cy = getTerrainHeight(cx, cz)
        stalkerPos = Vector3(x: cx, y: cy, z: cz)

  # Lógica de estados do jogo
  if gameState == StatePlaying:
    if isGameOver:
      discard
    else:
      if isKeyPressed(Escape):
        gameState = StateMainMenu
        enableCursor()

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

      let mouseDelta = getMouseDelta()
      cameraAngleX += mouseDelta.x * mouseSensitivity
      cameraAngleY -= mouseDelta.y * mouseSensitivity
      cameraAngleY = clamp(cameraAngleY, -1.5'f32, 1.5'f32)

      let forwardX = sin(cameraAngleX)
      let forwardZ = -cos(cameraAngleX)
      let rightX = cos(cameraAngleX)
      let rightZ = sin(cameraAngleX)

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
      
      # Física de Água: se estiver no rio (altura < -3.0), velocidade reduzida por causa da água
      let groundHeight = getTerrainHeight(camera.position.x, camera.position.z)
      let inWater = groundHeight < -3.0'f32

      var moveSpeed = if canSprint: 16.0'f32 else: 8.0'f32
      if inWater:
        moveSpeed *= 0.55'f32 # Redução de velocidade (resistência física da água)

      if isMoving:
        camera.position.x += (dx / len) * moveSpeed * dt
        camera.position.z += (dz / len) * moveSpeed * dt

      # --- Física de Gotas/Splashes de Água ao andar ---
      if isMoving and inWater and isGrounded:
        let spawnCount = int(1.0'f32 + gameRand() * 2.0'f32)
        for i in 0 ..< spawnCount:
          let startX = camera.position.x + (gameRand() - 0.5'f32) * 0.6'f32
          let startZ = camera.position.z + (gameRand() - 0.5'f32) * 0.6'f32
          let velX = (gameRand() - 0.5'f32) * 3.5'f32
          let velY = 1.5'f32 + gameRand() * 3.5'f32
          let velZ = (gameRand() - 0.5'f32) * 3.5'f32
          
          let pLifetime = 0.4'f32 + gameRand() * 0.4'f32
          let pSize = 0.08'f32 + gameRand() * 0.08'f32
          
          particles.add(SplashParticle(
            position: Vector3(x: startX, y: -3.0'f32, z: startZ),
            velocity: Vector3(x: velX, y: velY, z: velZ),
            color: Color(r: 180, g: 220, b: 255, a: 180),
            lifetime: pLifetime,
            maxLifetime: pLifetime,
            size: pSize
          ))

      # --- Colisão com Árvores ---
      const
        TreeCellSize = 20.0'f32
        TreeDensity = 0.15'f32
        PlayerRadius = 0.4'f32

      let pCellX = round(camera.position.x / TreeCellSize)
      let pCellZ = round(camera.position.z / TreeCellSize)

      for cz in -1 .. 1:
        for cx in -1 .. 1:
          let cellX = int(pCellX) + cx
          let cellZ = int(pCellZ) + cz

          var r = initRand(cellX, cellZ)
          if r.nextFloat() < TreeDensity:
            let offsetX = r.nextFloat() * TreeCellSize
            let offsetZ = r.nextFloat() * TreeCellSize
            let treeX = float32(cellX) * TreeCellSize + offsetX
            let treeZ = float32(cellZ) * TreeCellSize + offsetZ
            
            let treeY = getTerrainHeight(treeX, treeZ)
            if treeY >= 2.5'f32 or treeY < -3.0'f32:
              continue

            let trunkRadius = 0.25'f32 + r.nextFloat() * 0.2'f32

            let toPlayerX = camera.position.x - treeX
            let toPlayerZ = camera.position.z - treeZ
            let distSq = toPlayerX*toPlayerX + toPlayerZ*toPlayerZ
            let minDist = PlayerRadius + trunkRadius

            if distSq < minDist * minDist:
              let dist = sqrt(distSq)
              if dist > 0.001'f32:
                let overlap = minDist - dist
                camera.position.x += (toPlayerX / dist) * overlap
                camera.position.z += (toPlayerZ / dist) * overlap

      if not isGrounded:
        velY -= Gravity * dt
        camera.position.y += velY * dt

        if camera.position.y <= groundHeight + EyeHeight:
          camera.position.y = groundHeight + EyeHeight
          velY = 0.0'f32
          isGrounded = true
      else:
        camera.position.y = groundHeight + EyeHeight
        
        if isKeyPressed(Space):
          velY = JumpForce
          isGrounded = false

      camera.target.x = camera.position.x + targetDirX
      camera.target.y = camera.position.y + targetDirY
      camera.target.z = camera.position.z + targetDirZ

    # Lógica de Atualização de Partículas de Splashes
    var activeParticles: seq[SplashParticle] = @[]
    for i in 0 ..< particles.len:
      var p = particles[i]
      p.lifetime -= dt
      if p.lifetime > 0.0'f32:
        p.velocity.y -= 9.8'f32 * dt
        p.position.x += p.velocity.x * dt
        p.position.y += p.velocity.y * dt
        p.position.z += p.velocity.z * dt
        
        if p.position.y < -3.0'f32:
          p.position.y = -3.0'f32
          p.velocity = Vector3(x: 0, y: 0, z: 0)
          p.lifetime = min(p.lifetime, 0.1'f32)
          
        activeParticles.add(p)
    particles = activeParticles

  else:
    if isKeyPressed(Escape):
      if gameState == StateOptionsMenu:
        gameState = StateMainMenu
      else:
        shouldExit = true

    cameraAngleX += dt * 0.05'f32
    cameraAngleY = -0.2'f32
    
    let menuCamRadius = 40.0'f32
    camera.position.x = sin(cameraAngleX) * menuCamRadius
    camera.position.z = cos(cameraAngleX) * menuCamRadius
    camera.position.y = getTerrainHeight(camera.position.x, camera.position.z) + 10.0'f32
    
    camera.target = Vector3(x: 0.0'f32, y: getTerrainHeight(0.0'f32, 0.0'f32), z: 0.0'f32)

  # 5. Desenho do cenário
  drawing:
    let skyColor = getSkyColor(timeOfDay)
    
    clearBackground(skyColor)
    
    mode3D(camera):
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
          
          if distSq > 10.0'f32 * 10.0'f32:
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

          let dist = sqrt(distSq)
          let fogFactor = clamp((ViewDistance - dist) / 30.0'f32, 0.0'f32, 1.0'f32)
          let c1_fog = lerpColor(skyColor, c1, fogFactor)
          let c2_fog = lerpColor(skyColor, c2, fogFactor)
          
          drawTriangle3D(v00, v01, v10, c1_fog)
          drawTriangle3D(v10, v01, v11, c2_fog)

      # Desenha as árvores procedimentais
      drawTrees(camera, targetDirX, targetDirY, targetDirZ, lightMult, flashlightOn, skyColor)

      # Desenha a água procedimental com Shader
      beginShaderMode(waterShader)
      
      let timeLoc = getShaderLocation(waterShader, "uTime")
      var timeVal = float32(getTime())
      setShaderValue(waterShader, timeLoc, timeVal)
      
      let lightLoc = getShaderLocation(waterShader, "uLightMult")
      var lightVal = lightMult
      setShaderValue(waterShader, lightLoc, lightVal)
      
      let camLoc = getShaderLocation(waterShader, "uCameraPos")
      setShaderValue(waterShader, camLoc, camera.position)
      
      let flashOnLoc = getShaderLocation(waterShader, "uFlashlightOn")
      var flashOnVal = if flashlightOn: 1.int32 else: 0.int32
      setShaderValue(waterShader, flashOnLoc, flashOnVal)
      
      if flashlightOn:
        let flashPosLoc = getShaderLocation(waterShader, "uFlashlightPos")
        setShaderValue(waterShader, flashPosLoc, camera.position)
        let flashDirLoc = getShaderLocation(waterShader, "uFlashlightDir")
        setShaderValue(waterShader, flashDirLoc, targetDirVec)
        
      for cz in -halfCells .. halfCells:
        for cx in -halfCells .. halfCells:
          let x0 = gridCenterX + float32(cx) * Step
          let x1 = x0 + Step
          let z0 = gridCenterZ + float32(cz) * Step
          let z1 = z0 + Step
          
          let centerX = x0 + Step * 0.5'f32
          let centerZ = z0 + Step * 0.5'f32
          let centerY = -3.0'f32
          
          let toCellX = centerX - camera.position.x
          let toCellY = centerY - camera.position.y
          let toCellZ = centerZ - camera.position.z
          let distSq = toCellX*toCellX + toCellY*toCellY + toCellZ*toCellZ
          
          if distSq > 10.0'f32 * 10.0'f32:
            let dist = sqrt(distSq)
            let cosAngle = (toCellX * targetDirX + toCellY * targetDirY + toCellZ * targetDirZ) / dist
            if cosAngle < 0.5'f32:
              continue

          let y00 = getHeight(x0, z0)
          let y10 = getHeight(x1, z0)
          let y01 = getHeight(x0, z1)
          let y11 = getHeight(x1, z1)
          
          if y00 < -3.0'f32 or y10 < -3.0'f32 or y01 < -3.0'f32 or y11 < -3.0'f32:
            let w00 = Vector3(x: x0, y: -3.0'f32, z: z0)
            let w10 = Vector3(x: x1, y: -3.0'f32, z: z0)
            let w01 = Vector3(x: x0, y: -3.0'f32, z: z1)
            let w11 = Vector3(x: x1, y: -3.0'f32, z: z1)
            
            drawTriangle3D(w00, w01, w10, RayWhite)
            drawTriangle3D(w10, w01, w11, RayWhite)
            
      endShaderMode()

      # Desenha as partículas de água (gotas) com física e fog
      for p in particles:
        let toPartX = p.position.x - camera.position.x
        let toPartZ = p.position.z - camera.position.z
        let dist = sqrt(toPartX*toPartX + toPartZ*toPartZ)
        
        if dist < 80.0'f32:
          let fogFactor = clamp((80.0'f32 - dist) / 30.0'f32, 0.0'f32, 1.0'f32)
          let pColor = lerpColor(skyColor, p.color, fogFactor)
          let currentSize = p.size * (p.lifetime / p.maxLifetime)
          drawSphere(p.position, currentSize, pColor)

      # Desenha o stalker se estiver ativo (silhueta preta pura neblinada)
      if stalkerAtivo:
        let distX = stalkerPos.x - camera.position.x
        let distZ = stalkerPos.z - camera.position.z
        let dist = sqrt(distX*distX + distZ*distZ)
        
        let fogFactor = clamp((80.0'f32 - dist) / 30.0'f32, 0.0'f32, 1.0'f32)
        let stalkerColor = lerpColor(skyColor, Color(r: 0, g: 0, b: 0, a: 245), fogFactor)
        
        drawCylinder(stalkerPos, 0.25'f32, 0.25'f32, 1.8'f32, 6, stalkerColor)

    # UI 2D do Jogo
    let screenWidth = getScreenWidth().float32
    let screenHeight = getScreenHeight().float32

    if gameState == StateMainMenu:
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
        iniciarStalker(camera)
        stalkerLookTimer = 15.0'f32
        stalkerContagemRegressiva = 10.0'f32
        stalkerEmAlerta = false
        isGameOver = false

      if button(Rectangle(x: btnX, y: screenHeight/2 + 20, width: btnWidth, height: btnHeight), "Opcoes"):
        gameState = StateOptionsMenu

      if button(Rectangle(x: btnX, y: screenHeight/2 + 80, width: btnWidth, height: btnHeight), "Sair"):
        shouldExit = true

    elif gameState == StateOptionsMenu:
      let title = "OPCOES"
      let titleFontSize = 40.int32
      let titleWidth = measureText(title, titleFontSize).float32
      drawText(title, int32(screenWidth/2 - titleWidth/2), int32(screenHeight/2 - 150), titleFontSize, RayWhite)

      let optWidth = 220.float32
      let optHeight = 30.float32
      let optX = screenWidth/2 - optWidth/2

      if checkBox(Rectangle(x: optX, y: screenHeight/2 - 40, width: 20, height: 20), "Tela Cheia", isFullscreenState):
        toggleFullscreen()

      var sensValue = mouseSensitivity * 1000.0'f32
      if slider(Rectangle(x: optX, y: screenHeight/2, width: 150, height: 20), "Sensibilidade: ", fmt"{sensValue:.1f}", sensValue, 1.0'f32, 10.0'f32):
        mouseSensitivity = sensValue / 1000.0'f32

      if button(Rectangle(x: optX, y: screenHeight/2 + 60, width: optWidth, height: 40), "Voltar"):
        gameState = StateMainMenu

    elif isGameOver:
      drawRectangle(0, 0, int32(screenWidth), int32(screenHeight), Color(r: 0, g: 0, b: 0, a: 255))
      
      let goText = "VOCE FOI CONSUMIDO PELA ESCURIDAO"
      let goFontSize = 32.int32
      let goTextWidth = measureText(goText, goFontSize).float32
      drawText(goText, int32(screenWidth/2 - goTextWidth/2), int32(screenHeight/2 - 100), goFontSize, Red)

      let btnWidth = 220.float32
      let btnHeight = 40.float32
      let btnX = screenWidth/2 - btnWidth/2

      if button(Rectangle(x: btnX, y: screenHeight/2 + 10, width: btnWidth, height: btnHeight), "Tentar Novamente"):
        let startHeight = getTerrainHeight(0.0'f32, 0.0'f32)
        camera.position = Vector3(x: 0.0'f32, y: startHeight + EyeHeight, z: 0.0'f32)
        camera.target = Vector3(x: 0.0'f32, y: startHeight + EyeHeight, z: -1.0'f32)
        cameraAngleX = 0.0'f32
        cameraAngleY = 0.0'f32
        velY = 0.0'f32
        isGrounded = true
        timeOfDay = 12.0'f32
        flashlightOn = false
        flashlightBattery = 1.0'f32
        stamina = 1.0'f32
        
        iniciarStalker(camera)
        stalkerLookTimer = 15.0'f32
        stalkerContagemRegressiva = 10.0'f32
        stalkerEmAlerta = false
        isGameOver = false
        disableCursor()

      if button(Rectangle(x: btnX, y: screenHeight/2 + 70, width: btnWidth, height: btnHeight), "Voltar ao Menu"):
        gameState = StateMainMenu
        isGameOver = false

    else:
      # --- JOGO ATIVO (UI UNIFICADA DE STATUS) ---
      let hours = int(timeOfDay)
      let minutes = int((timeOfDay - float32(hours)) * 60.0'f32)
      let timeStr = fmt"{hours:02}:{minutes:02}"
      
      let hasFlashlight = flashlightBattery < 1.0'f32
      let hasStamina = stamina < 1.0'f32
      
      let panelWidth = 240.float32
      let panelX = screenWidth - panelWidth - 20.float32
      let panelY = 20.float32
      
      var panelHeight = 40.float32
      if hasFlashlight: panelHeight += 30.float32
      if hasStamina: panelHeight += 30.float32
      
      panel(Rectangle(x: panelX, y: panelY, width: panelWidth, height: panelHeight), "")
      
      label(Rectangle(x: panelX + 15.float32, y: panelY + 10.float32, width: panelWidth - 30.float32, height: 20.float32), "Hora: " & timeStr)
      
      var elementY = panelY + 40.float32
      let pbWidth = 140.float32
      let pbHeight = 16.float32
      let pbX = panelX + 85.float32
      
      if hasFlashlight:
        progressBar(Rectangle(x: pbX, y: elementY, width: pbWidth, height: pbHeight), "Lanterna", "", flashlightBattery, 0.0'f32, 1.0'f32)
        elementY += 30.float32
        
      if hasStamina:
        progressBar(Rectangle(x: pbX, y: elementY, width: pbWidth, height: pbHeight), "Energia", "", stamina, 0.0'f32, 1.0'f32)
        elementY += 30.float32

      if stalkerEmAlerta:
        let alpha = clamp((10.0'f32 - stalkerContagemRegressiva) / 10.0'f32, 0.0'f32, 1.0'f32)
        let alphaByte = uint8(alpha * 255.0'f32)
        drawRectangle(0, 0, int32(screenWidth), int32(screenHeight), Color(r: 0, g: 0, b: 0, a: alphaByte))
        
        let alertText = "ALGO ESTA SE APROXIMANDO... PROCURE-O!"
        let alertFontSize = 20.int32
        let alertTextWidth = measureText(alertText, alertFontSize).float32
        let textAlpha = uint8(150 + int(sin(getTime() * 8.0) * 105.0))
        drawText(alertText, int32(screenWidth/2 - alertTextWidth/2), int32(screenHeight - 80), alertFontSize, Color(r: 220, g: 0, b: 0, a: textAlpha))

closeWindow()
