# Build script for Rice University Thesis (PowerShell version)
# Compiles LaTeX to a build directory (PDF and auxiliary files stay in .build/)
# Usage: .\build.ps1 [path/to/file.tex]
#        If no argument provided, checks for .tex files in the current directory

param(
    [string]$TexFile = ""
)

# Get the .tex file path from first argument or find one in current directory
if ($TexFile -eq "") {
    # Find all .tex files in current directory
    $texFiles = Get-ChildItem -Path . -Filter "*.tex" -File | Sort-Object Name
    
    if ($texFiles.Count -eq 0) {
        $TexFile = ""
    } elseif ($texFiles.Count -eq 1) {
        # Only one file, use it
        $TexFile = $texFiles[0].Name
    } else {
        # Multiple files found - prompt user to choose (style matches compilation output)
        $separator = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-Host ""
        Write-Host $separator -ForegroundColor Cyan
        Write-Host "  Select .tex file to build" -ForegroundColor Cyan
        Write-Host $separator -ForegroundColor Cyan
        Write-Host ""
        for ($i = 0; $i -lt $texFiles.Count; $i++) {
            Write-Host "  [$($i + 1)] " -NoNewline -ForegroundColor DarkGray
            Write-Host $texFiles[$i].Name -ForegroundColor Cyan
        }
        Write-Host ""
        $selection = Read-Host "  Select (1-$($texFiles.Count)) or Enter to cancel"
        
        if ($selection -eq "" -or $selection -eq "q" -or $selection -eq "Q") {
            Write-Host "Build cancelled." -ForegroundColor DarkGray
            exit 0
        }
        
        $selectedIndex = [int]$selection - 1
        if ($selectedIndex -ge 0 -and $selectedIndex -lt $texFiles.Count) {
            $TexFile = $texFiles[$selectedIndex].Name
            Write-Host "Selected: $TexFile" -ForegroundColor Green
        } else {
            Write-Host "Invalid selection. Build cancelled." -ForegroundColor Red
            exit 1
        }
    }
}

if ($TexFile -eq "" -or -not (Test-Path $TexFile)) {
    Write-Host "Error: No .tex file found. Usage: .\build.ps1 [filename.tex]" -ForegroundColor Red
    exit 1
}

# Save the original directory to return to it later
$OriginalDir = Get-Location

# Get absolute path and extract directory and basename
$TexFileAbs = Resolve-Path $TexFile
$TexDir = Split-Path -Parent $TexFileAbs
$BaseName = [System.IO.Path]::GetFileNameWithoutExtension($TexFileAbs)
$BuildDir = Join-Path $TexDir ".build"

# Create build directory and subdirs for \include{}/\subfile{} paths (LaTeX won't create parent dirs)
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
if (Test-Path $TexFileAbs) {
  $content = Get-Content $TexFileAbs -Raw -ErrorAction SilentlyContinue
  if ($content) {
    [regex]::Matches($content, '\\(include|subfile)\{([^}]+)\}') | ForEach-Object {
      $path = $_.Groups[2].Value
      $dir = Split-Path -Parent $path
      if ($dir -and $dir -ne ".") {
        New-Item -ItemType Directory -Force -Path (Join-Path $BuildDir $dir) | Out-Null
      }
    }
  }
}

# Find project root (directory containing main.tex)
$ProjectRoot = $OriginalDir
while ($ProjectRoot -and -not (Test-Path (Join-Path $ProjectRoot "main.tex"))) {
    $ProjectRoot = Split-Path -Parent $ProjectRoot
}

# Change to the directory containing the .tex file for compilation
Set-Location $TexDir

# Compile to build directory
$texFileName = Split-Path -Leaf $TexFileAbs
$separator = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host ""
Write-Host $separator -ForegroundColor Cyan
Write-Host "  Compiling: " -NoNewline -ForegroundColor Cyan; Write-Host $texFileName -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

# Set TEXINPUTS to include project root so subfiles can find included files
if ($ProjectRoot) {
    $env:TEXINPUTS = "$ProjectRoot;$env:TEXINPUTS"
    $env:BIBINPUTS = "$ProjectRoot;$env:BIBINPUTS"
}

# Start timing
$startTime = Get-Date

# First pass: pdflatex
Write-Host "  [1/3] Running pdflatex..." -ForegroundColor DarkGray
$null = pdflatex -output-directory="$BuildDir" -interaction=nonstopmode -synctex=1 "$texFileName" 2>&1

# Check if bibliography needs to be compiled (for main.tex or files using natbib)
if ($texFileName -eq "main.tex" -or $BaseName -eq "main") {
    Write-Host "  [   ] Running bibtex..." -ForegroundColor DarkGray
    $null = bibtex -output-directory="$BuildDir" "$BaseName" 2>&1
}

# Second pass: pdflatex (to incorporate bibliography)
Write-Host "  [2/3] Running pdflatex..." -ForegroundColor DarkGray
$null = pdflatex -output-directory="$BuildDir" -interaction=nonstopmode -synctex=1 "$texFileName" 2>&1

# Third pass: pdflatex (to resolve all references)
Write-Host "  [3/3] Running pdflatex..." -ForegroundColor DarkGray
$null = pdflatex -output-directory="$BuildDir" -interaction=nonstopmode -synctex=1 "$texFileName" 2>&1

# Check if PDF was created
$pdfPath = Join-Path $BuildDir "$BaseName.pdf"
$logPath = Join-Path $BuildDir "$BaseName.log"

if (Test-Path $pdfPath) {
    # Calculate compilation time (integer seconds to match bash)
    $endTime = Get-Date
    $elapsed = [math]::Floor(($endTime - $startTime).TotalSeconds)
    
    # Get PDF info (format to match du -h output: "200K" or "1.2M")
    $pdfFile = Get-Item $pdfPath
    $sizeBytes = $pdfFile.Length
    if ($sizeBytes -lt 1KB) {
        $pdfSize = "$sizeBytes"
    } elseif ($sizeBytes -lt 1MB) {
        $pdfSize = "{0}K" -f [math]::Round($sizeBytes / 1KB)
    } else {
        $pdfSize = "{0:N1}M" -f ($sizeBytes / 1MB)
        # Remove trailing .0 if present to match du -h format
        $pdfSize = $pdfSize -replace '\.0([KM])', '$1'
    }
    
    # Try to get page count (multiple methods for compatibility)
    $pageCount = $null
    if (Get-Command pdfinfo -ErrorAction SilentlyContinue) {
        $pageInfo = pdfinfo $pdfPath 2>$null | Select-String "^Pages:"
        if ($pageInfo) {
            $pageCount = ($pageInfo -split '\s+')[1]
        }
    } elseif (Get-Command pdftk -ErrorAction SilentlyContinue) {
        $pageInfo = pdftk $pdfPath dump_data 2>$null | Select-String "NumberOfPages"
        if ($pageInfo) {
            $pageCount = ($pageInfo -split '\s+')[1]
        }
    }
    
    # Parse log file for errors and warnings
    $errorCount = 0
    $warningCount = 0
    if (Test-Path $logPath) {
        $errorCount = (Select-String -Path $logPath -Pattern "^!" -AllMatches).Matches.Count
        $warningPatterns = @(
            "^LaTeX Warning:",
            "^Package .* Warning:",
            "^Overfull",
            "^Underfull",
            "^Font shape",
            "^Missing character"
        )
        foreach ($pattern in $warningPatterns) {
            $warningCount += (Select-String -Path $logPath -Pattern $pattern -AllMatches).Matches.Count
        }
    }

    # Display path: relative to OriginalDir when under it
    $originalDirStr = $OriginalDir.Path
    if ($pdfPath.StartsWith($originalDirStr)) {
        $displayPath = $pdfPath.Substring($originalDirStr.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    } else {
        $displayPath = "$BaseName.pdf (in .build/)"
    }

    Write-Host ""
    Write-Host "✓ Success" -ForegroundColor Green
    # One-line summary
    $summary = "$BaseName.pdf"
    if ($pageCount) { $summary += " · $pageCount page(s)" }
    if ($pdfSize) { $summary += " · $pdfSize" }
    if ($elapsed -gt 0) { $summary += " · ${elapsed}s" }
    Write-Host "  $summary" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "  Output:" -ForegroundColor White
    Write-Host "    File:   $displayPath" -ForegroundColor DarkGray
    if ($pageCount) { Write-Host ("    {0,-7} {1}" -f "Pages:", $pageCount) -ForegroundColor DarkGray }
    if ($pdfSize) { Write-Host ("    {0,-7} {1}" -f "Size:", $pdfSize) -ForegroundColor DarkGray }
    if ($elapsed -gt 0) { Write-Host ("    {0,-7} {1}" -f "Time:", "${elapsed}s") -ForegroundColor DarkGray }

    if ($errorCount -gt 0 -or $warningCount -gt 0) {
        Write-Host ""
        Write-Host "  ⚠ Issues:" -ForegroundColor Yellow
        if ($errorCount -gt 0) { Write-Host "    Errors:   $errorCount" -ForegroundColor Red }
        if ($warningCount -gt 0) { Write-Host "    Warnings: $warningCount" -ForegroundColor Yellow }
        Write-Host "    Log:     $logPath" -ForegroundColor DarkGray
    }
} else {
    Write-Host ""
    Write-Host "✗ Compilation Failed" -ForegroundColor Red
    Write-Host ""
    if (Test-Path $logPath) {
        $errorCount = (Select-String -Path $logPath -Pattern "^!" -AllMatches).Matches.Count
        $warningPatterns = @(
            "^LaTeX Warning:",
            "^Package .* Warning:",
            "^Overfull",
            "^Underfull",
            "^Font shape",
            "^Missing character"
        )
        $warningCount = 0
        foreach ($pattern in $warningPatterns) {
            $warningCount += (Select-String -Path $logPath -Pattern $pattern -AllMatches).Matches.Count
        }
        Write-Host "  Issues Found:" -ForegroundColor White
        if ($errorCount -gt 0) { Write-Host "    Errors:   $errorCount" -ForegroundColor Red }
        if ($warningCount -gt 0) { Write-Host "    Warnings: $warningCount" -ForegroundColor Yellow }
        Write-Host "    Log:     $logPath" -ForegroundColor DarkGray
    } else {
        Write-Host "  Log file not found: $logPath" -ForegroundColor DarkGray
    }
    Write-Host ""
    Set-Location $OriginalDir
    exit 1
}

# Return to the original directory
Set-Location $OriginalDir
