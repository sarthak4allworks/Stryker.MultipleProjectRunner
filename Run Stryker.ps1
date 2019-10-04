function RunForOneAssembly ($csprojPath, $testPath, $solutionPath, $outputPath) {
    Write-Host "csprojPath: " $csprojPath
    Write-Host "Moving to test directory: $testPath"

    Set-Location $testPath

    Write-Host "Calling Stryker"
    dotnet stryker --project-file "$csprojPath" --solution-path $solutionPath --reporters "['json', 'progress']"

    if( -not $? ){
        Write-Host "Error in running Stryker, exiting the script"
        # write error output to Azure DevOps
        Write-Host "##vso[task.complete result=Failed;]Error"
        exit;
    }

    $searchPath = Split-Path -Path $testPath
    Write-Host "Searching for json files in this path: $searchPath"
    # find all json result files and use the most recent one
    $files = Get-ChildItem -Path "$searchPath"  -Filter "*.json" -Recurse -ErrorAction SilentlyContinue -Force
    $file = $files | Sort-Object {$_.LastWriteTime} | Select-Object -last 1
    
    # get the name and the timestamp of the file
    $orgReportFilePath=$file.FullName
    $splitted = $splitted = $orgReportFilePath.split("\")
    $dateTimeStamp = $splitted[$splitted.Length - 3]
    $fileName =  $splitted[$splitted.Length - 1]
    Write-Host "Last file filename: $orgReportFilePath has timestamp: $dateTimeStamp"

    # create a new filename to use in the output
    New-Item $outputPath -ItemType "directory" -Force
    $newFileName = "$outputPath" + $dateTimeStamp + "_"+ $fileName
    Write-Host "Copy the report file to '$newFileName'"
    # write the new file out to the report directory
    Copy-Item "$orgReportFilePath" "$newFileName"
}

function JoinStykerJsonFile ($additionalFile, $joinedFileName) {
    # Stryker report json files object is not an array :-(, so we cannot join them and have to do it manually
    $report = (Get-Content $joinedFileName | Out-String)
    $additionalContent = (Get-Content $additionalFile | Out-String)

    $searchString = '"files": {'
    $searchStringLength = $searchString.Length
    $startCopy = $additionalContent.IndexOf($searchString)
    $offSet = 9
    $copyText = $additionalContent.Substring($startCopy+$searchStringLength, $additionalContent.Length-$offSet-$startCopy-$searchStringLength)
        
    # save the first part of the report file
    $startCopy = $report.Substring(0, $report.Length-$offSet)
    # add in the new copy text
    $startCopy = $startCopy + ",`r`n" + $copyText
    # add in the end of the file again
    $fileEnding = $report.Substring($report.Length-$offSet, $offSet)
    $startCopy = $startCopy + $fileEnding

    # save the new file to disk
    Set-Content -Path $joinedFileName -Value $startCopy
}

function JoinJsonWithHtmlFile ($joinedJsonFileName, $reportFileName, $emptyReportFileName, $reportTitle) {
    $report = (Get-Content $emptyReportFileName | Out-String)
    $Json = (Get-Content $joinedJsonFileName | Out-String)

    $report = $report.Replace("##REPORT_JSON##", $Json)
    $report = $report.Replace("##REPORT_TITLE##", $reportTitle)
    # hardcoded link to the package from the npm CDN
    $report = $report.Replace("<script>##REPORT_JS##</script>", '<script defer src="https://www.unpkg.com/mutation-testing-elements"></script>')
        
    Set-Content -Path $reportFileName -Value $report
}

function JoinAllJsonFiles ($joinedFileName) {
    $files = Get-ChildItem  -Filter "*.json" -Exclude $joinedFileName -Recurse -ErrorAction SilentlyContinue -Force
    Write-Host "Found $($files.Count) json files to join"
    $firstFile = $true
    foreach ($file in $files) {
        if ($true -eq $firstFile) {
            # copy the first file as is
            Copy-Item $file.FullName "$joinedFileName"
            $firstFile = $false
            continue
        }

        JoinStykerJsonFile $file.FullName $joinedFileName
    }
    Write-Host "Joined $($files.Count) files to the new json file: $joinedFileName"
}

# save where we started
$startDir = Get-Location
Write-Host "Starting at: " $startDir
try {
    # load the data file
    $strykerDataFilePath = "$startDir\Stryker.data.json"
    $strykerData = (Get-Content $strykerDataFilePath | Out-String | ConvertFrom-Json)

    # check for errors
    if( -not $?) {
        exit;
    }

    # clear the output path
    Write-Host "Deleting previous json files from $($strykerData.jsonReportsPath)"
    Get-ChildItem -Path "$($strykerData.jsonReportsPath)" -Include *.json -File -Recurse | ForEach-Object { $_.Delete()}

    # mutate all projects in the data file
    $counter = 1
    foreach ($project in $strykerData.projectsToTest) {
        Write-Host "Running mutation for project $($counter) of $($strykerData.projectsToTest.Length)"

        RunForOneAssembly $project.csprojPath $project.testPath $strykerData.solutionPath $strykerData.jsonReportsPath
        $counter++
    }

    # check for errors
    if( -not $?) {
        exit;
    }

    # Join all the json files
    Set-Location "$startDir\Output"
    $joinedJsonFileName = "mutation-report.json"

    JoinAllJsonFiles $joinedJsonFileName

    # join the json with the html template for the final output
    $reportFileName = "StrykerReport.html"
    $emptyReportFileName = "$startDir\StrykerReportEmpty.html"
    $reportTitle = "Stryker Mutation Testing"
    JoinJsonWithHtmlFile $joinedJsonFileName $reportFileName $emptyReportFileName $reportTitle

    Write-Host "Created new report file: $startDir\Output\$reportFileName"
}
finally {
    # change back to the starting directory
    Set-Location $startDir
}