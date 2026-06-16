$script_dir = $PSScriptRoot
Set-Location $script_dir

$runs = 25
$workloads = @("bench_arith", "bench_array", "bench_map", "bench_string", "bench_call", "bench_control", "bench_sieve")
$workload_labels = @("arith", "array", "map", "string", "call", "control", "sieve")
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
$na = @{}

Write-Host "Running benchmarks ($runs runs each)..."
Write-Host ""

foreach ($lang in $lang_configs) {
    $name = $lang.name
    Write-Host "[$name]"

    for ($w = 0; $w -lt $workloads.Length; $w++) {
        $wl = $workloads[$w]
        $label = $workload_labels[$w]
        $file = "$($wl)$($lang.ext)"

        if (-not (Test-Path $file)) {
            Write-Host "  $label ... N/A"
            $na["$name-$wl"] = $true
            continue
        }

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
$md_lines += "| workload | kiln                   | lua                    | python                  | umka                   |"
$md_lines += "|----------|------------------------|------------------------|-------------------------|------------------------|"

for ($w = 0; $w -lt $workloads.Length; $w++) {
    $label = $workload_labels[$w]
    $cells = @("{0,-8}" -f $label)
    foreach ($lang in $lang_configs) {
        $name = $lang.name
        $key = "$name-$($workloads[$w])"
        if ($na[$key]) {
            $cells += "{0,23}" -f "N/A"
        } elseif ($results[$key]) {
            $r = $results[$key]
            $cells += "{0,7:F2}, {1,7:F2}, {2,7:F2}" -f $r.min, $r.med, $r.max
        } else {
            $cells += "{0,23}" -f "ERR"
        }
    }
    $md_lines += "| $($cells[0]) | $($cells[1]) | $($cells[2]) | $($cells[3])  | $($cells[4]) |"
}

$md_text = $md_lines -join "`r`n"
$md_text | Out-File -FilePath "results.md" -Encoding ASCII
Write-Host ""
Write-Host "Results:"
Write-Host $md_text
Write-Host ""
Write-Host "Done. Results saved to results.md"
