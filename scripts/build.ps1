param([string]$CltRoot = 'C:\Program Files\command-line-tools')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $repoRoot
$previousNodePath = $env:NODE_PATH
try {
  $wrapperVersion = (Get-Content -Raw -LiteralPath (Join-Path $CltRoot 'hvigor/hvigor/package.json') | ConvertFrom-Json).version
  $cacheHash = & node -e 'console.log(require("crypto").createHash("sha256").update(process.cwd()+":"+process.argv[1]).digest("hex").slice(0,32))' $wrapperVersion
  if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the Hvigor project cache' }
  $env:NODE_PATH = Join-Path $env:USERPROFILE ".hvigor/project_caches/$cacheHash/workspace/node_modules"
  & devecocli build
  if ($LASTEXITCODE -ne 0) { throw 'DevEco build failed' }
} finally {
  $env:NODE_PATH = $previousNodePath
  Pop-Location
}
