$script_dir = $PSScriptRoot
Set-Location $script_dir

$runs = 5
$workloads = @("bench_arith", "bench_array", "bench_map", "bench_string")
$workload_labels = @("arith", "array", "map", "string")
$lang_configs = @(
    @{name="kiln";   ext=".kiln"},
    @{name="lua";    ext=".lua"},
    @{name="python"; ext=".py"},
    @{name="umka";   ext=".um"}
)

function Run-One($name, $file, $ext) {
    switch ($name) {
        "kiln"   { & "$script_dir\..\kiln.exe" $file *>$null }
        "lua"    { & "C:\Program Files (x86)\Lua\5.1\lua.exe" "$file$ext" *>$null }
        "python" { py "$file$ext" *>$null }
        "umka"   { umka "$file$ext" *>$null }
    }
}

$results = @{}

Write-Host "Running benchmarks ($runs runs each)..."
Write-Host ""

foreach ($lang in $lang_configs) {
    $name = $lang.name
    Write-Host "[$name]"

    for ($w = 0; $w -lt $workloads.Length; $w++) {
        $wl = $workloads[$w]
        $label = $workload_labels[$w]
        Write-Host "  $label ..." -NoNewline

        $times = @()
        for ($i = 0; $i -lt $runs; $i++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Run-One $name $wl $lang.ext
            $sw.Stop()
            $times += $sw.Elapsed.TotalMilliseconds
        }

        $sorted = $times | Sort-Object
        $minVal = $sorted[0]
        $medVal = $sorted[2]
        $maxVal = $sorted[4]

        $results["$name-$wl"] = @{
            min = $minVal
            med = $medVal
            max = $maxVal
        }

        Write-Host " done"
    }
}

$md_lines = @()
$md_lines += "# Benchmark Results (ms, $runs runs)"
$md_lines += ""
$md_lines += "| lang | workload | min | med | max |"
$md_lines += "|------|----------|-----|-----|-----|"

foreach ($lang in $lang_configs) {
    $name = $lang.name
    for ($w = 0; $w -lt $workloads.Length; $w++) {
        $wl = $workloads[$w]
        $label = $workload_labels[$w]
        $r = $results["$name-$wl"]
        $row = "| {0,-6} | {1,-8} | {2,7:F2} | {3,7:F2} | {4,7:F2} |" -f $name, $label, $r.min, $r.med, $r.max
        $md_lines += $row
    }
}

$md_text = $md_lines -join "`r`n"
$md_text | Out-File -FilePath "results.md" -Encoding ASCII
Write-Host ""
Write-Host "Results:"
Write-Host $md_text
Write-Host ""
Write-Host "Done. Results saved to results.md"
