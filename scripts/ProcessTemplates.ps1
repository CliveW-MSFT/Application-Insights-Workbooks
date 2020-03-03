$mainPath = Split-Path (split-path -parent $MyInvocation.MyCommand.Path) -Parent
$localizeRoot = Convert-Path "$mainPath\scripts"
$outputPath = "$mainPath\output"

$reportTypes = @('Cohorts', 'Workbooks')
$templateExtensions = @('cohort', 'workbook')
$defaultLanguage = 'en-us'
$payload = @{ }
$categoryMetadataFileName = 'categoryResources.json'

# This is the name of where the blob that ALM looks for
$azureBlobFileNameBase = "community-templates-V2";

$repoBaseName = "Application-Insights-Workbooks"
$supportedLanguages = @(
    "cs-cz", 
#    "de-de",
#    "es-es", 
#    "fr-fr", 
#    "hu-hu", 
#    "it-it", 
#    "ja-jp", 
#    "ko-kr",
#    "nl-nl", 
#    "pl-pl", 
#    "pt-br", 
#    "pt-pt", 
#    "ru-ru", 
#    "sv-se", 
#    "tr-tr", 
#    "zh-cn", 
#    "zh-tw",
    $defaultLanguage
)
$docGitServer = "https://github.com/MicrosoftDocs/"

#----------------------------------------------------------------------------
# GetTemplateContainerData
# get all of the template info in the given path for the given language, 
# and either embed the full content of the template into the object, or copy it to a folder
#----------------------------------------------------------------------------
Function GetTemplateContainerData() {
    param(
        [String] $templateFolderPath,
        [String] $language,
        [String] $copyToPath # if specified, the content will be copied to this path instead of embedded inside the results
    )   
    
    $templateMetadata = @{ }

    CopyFromEnuIfNotExist $templateFolderPath $language
    $templateFiles = Get-ChildItem $templateFolderPath

    $hasFoundTemplateContent = $false

    # look for settings first so we have all the metadata
    $templateFilePath = "$templateFolderPath\settings.json"
    if (!(Test-Path $templateFilePath)) {
        Write-Host "Directory $templateFolderPath missing settings.json, does not appear to be a template folder"
        continue;
    }
    $templateSettings = Get-Content $templateFilePath -Encoding UTF8 | Out-String | ConvertFrom-Json 

    # Build path of file
    $templateFolderName = Split-Path $templateFolderPath -Leaf
    $templateCategoryFolderPath = Split-Path $templateFolderPath
    $templateCategory = Split-Path $templateCategoryFolderPath -Leaf
    $templateReportTypePath = Split-Path $templateCategoryFolderPath
    $templateReportType = Split-Path $templateReportTypePath -Leaf

    $templateMetadata.path = "$templateReportType/$templateCategory/$templateFolderName"
    $templateId = "$templateReportType-$templateCategory-$templateFolderName"
    $templateMetadata.name = $templateSettings.name
    $templateMetadata.author = $templateSettings.author
    if (![string]::IsNullOrEmpty($templateSettings.description)) {
        $templateMetadata.description = $templateSettings.description
    }
    if (!($null -eq $templateSettings.tags)) {
        $templateMetadata.tags = $templateSettings.tags
    }
    if (!($null -eq $templateSettings.galleries)) {
        $templateMetadata.galleries = $templateSettings.galleries
    }
    if (![string]::IsNullOrEmpty($templateSettings.icon)) {
        $templateMetadata.iconUrl = $templateSettings.icon
    }
    if (![string]::IsNullOrEmpty($templateSettings.readme)) {
        $templateMetadata.readme = $templateSettings.readme
    }
    if (![string]::IsNullOrEmpty($templateSettings.isPreview)) {
        $templateMetadata.isPreview = $templateSettings.isPreview
    }

    foreach ($templateFile in $templateFiles) {

        if ($templateFile.Name -eq 'settings.json') {
            #already handled above
            continue;
        }
        elseif ($templateExtensions.Contains($templateFile.Name.split(".")[-1])) {
            $fullName = $templateFile.FullName
            if ($hasFoundTemplateContent) {
                Write-Host "[#WARNING: IGNORING File: There cannot be more than one content file per template, ignoring $fullName"
                continue;
            }

            $hasFoundTemplateContent = $true

            # This is the template content for default language
            if ($null -eq $copyToPath) {
                $templateMetadata.Content = Get-Content $fullName -Encoding UTF8 | Out-String
            } else {
                $ext = $templateFile.Extension
                if (!(Test-Path "$copyToPath\\$lang")) {
                    mkdir "$copyToPath\\$lang"
                }

                $packageFullPath = "$copyToPath\\$lang\\$templateId$ext"
                if (Test-Path $packageFullPath) {
                    Write-Host "[#ERROR: duplicate template path $packageFullPath"
                }
   
                $templateMetadata.FilePath = "$templateId$ext"
                Copy-Item -Path $fullName -Destination $packageFullPath
            }

        }
    }

    if ( $null -eq $templateMetadata.path -or ($null -eq $copyToPath -and $null -eq $templateMetadata.Content)) {
        throw "Template in folder $templateFolderPath is missing properties"
    }

    return $templateMetadata;
}

#----------------------------------------------------------------------------
# AddCategory
#----------------------------------------------------------------------------
Function AddCategory() {
    param(
        [string] $categoryName,
        [Object] $categories,
        [Object] $categorySettings,
        [string] $language
    )

    if ($categories.$categoryName) {
        throw "Cannot have duplicate category names ($categoryName)"
    }

    $categories.$categoryName = @{ }

    $categories.$categoryName.ReportName = $reportType
    $categories.$categoryName.CategoryName = $categoryName
    $categories.$categoryName.TemplateContainers = @()

    $categories.$categoryName.SortOrderByLanguage = @{ }
    $categories.$categoryName.NameByLanguage = @{ }
    $categories.$categoryName.DescriptionByLanguage = @{ }

    $categorySettings | Get-Member -type NoteProperty | Foreach-Object {
        # only process language in categoryResources.json
        if ($_.name -eq $language) {
            $languageProperties = $categorySettings.($_.name)

            $categories.$categoryName.SortOrderByLanguage.($_.name) = $languageProperties.order
            $categories.$categoryName.NameByLanguage.($_.name) = $languageProperties.name
            $categories.$categoryName.DescriptionByLanguage.($_.name) = $languageProperties.description
        }
    }
}

#----------------------------------------------------------------------------
# AddVirtualCategories
#----------------------------------------------------------------------------
Function AddVirtualCategories() {
    param(
        [Object] $categories,
        [string] $categoriesMetadataFilePath,
        [string] $language
    )

    $virtualCategoriesSettings = Get-Content $categoriesMetadataFilePath -Encoding UTF8 | Out-String | ConvertFrom-Json 

    foreach ($virtualCategory in $virtualCategoriesSettings.categories) {

        AddCategory $virtualCategory.key $categories $virtualCategory.settings $language
    }
}

#----------------------------------------------------------------------------
# AddTemplatesToVirtualGallery
#----------------------------------------------------------------------------
Function AddTemplatesToVirtualGallery() {

    param(
        [Object] $templateMetadata,
        [String] $language
    )

    $lang = CheckLanguageOrUseDefault $language

    $virtualGalleries = $templateMetadata.TemplateByLanguage.$lang.galleries | Where-Object { ($null -ne $_.categoryKey) -and $payload.$reportType.($_.categoryKey) }

    if ($null -ne $virtualGalleries) {

        # Only keep non-virtual galleries in path category
        $nonVirtualGalleries = $templateMetadata.TemplateByLanguage.$lang.galleries | Where-Object { $null -eq $_.categoryKey }
        if ($null -eq $nonVirtualGalleries) {
            $templateMetadata.TemplateByLanguage.$lang.galleries = @()
        }
        elseif ($null -eq $nonVirtualGalleries.Count) {
            $templateMetadata.TemplateByLanguage.$lang.galleries = @($nonVirtualGalleries)
        }
        else {
            $templateMetadata.TemplateByLanguage.$lang.galleries = $nonVirtualGalleries
        }

        # Means there is only one Virtual gallery, so virtual galleries is an object not a list
        if ($null -eq $virtualGalleries.Count) {
            $newTemplateData = (Copy-Object  $templateMetadata)[0]

            $newTemplateData.TemplateByLanguage.$lang.galleries = @($virtualGalleries)
            $payload.$reportType.($virtualGalleries.categoryKey).TemplateContainers += $newTemplateData
        }
        else {
            $virtualGalleries | ForEach-Object {

                $newTemplateData = (Copy-Object  $templateMetadata)[0]
                $newTemplateData.TemplateByLanguage.$lang.galleries = @($_)
                $payload.$reportType.($_.categoryKey).TemplateContainers += $newTemplateData
            }
        }
    }
}

#----------------------------------------------------------------------------
# Copy-Object
#----------------------------------------------------------------------------
function Copy-Object {
    param($DeepCopyObject)
    $memStream = new-object IO.MemoryStream
    $formatter = new-object Runtime.Serialization.Formatters.Binary.BinaryFormatter
    $formatter.Serialize($memStream, $DeepCopyObject)
    $memStream.Position = 0
    $formatter.Deserialize($memStream)

    return $formatter
}

#----------------------------------------------------------------------------
# CloneAndPullLocalizedRepos
#----------------------------------------------------------------------------
Function CloneAndPullLocalizedRepos {
    # repros will be downloaded to .\scripts folder
    # to make this run like pipeline build, we'll only clone the repo and not due a pul
    # for testing, delete the repos each time
    $rootPath = $localizeRoot

    Push-Location
    foreach ($lang in $supportedLanguages) {
        if ($lang -eq $defaultLanguage) {
            continue;
        }
        $repoName = "$repoBaseName.$lang"
        $repoPath = "$rootPath\$repoName"
        if (Test-Path $lang) {
            Write-Host "Repo exist on disk, skipping $repoPath ..."
            #Set-Location -Path $repoPath
            #git pull
        } else {
            Write-Host "Cloning $docGitServer$repoName.git at $lang ..."
            git clone "$docGitServer$repoName.git" $lang
        }
    }
    Pop-Location
}

#----------------------------------------------------------------------------
# after this method completes, the $language folder has either content from
# its own localized repo OR the english one, but all files in the english repo exist in this one too
#----------------------------------------------------------------------------
Function CopyFromEnuIfNotExist() {
    param(
        [string] $fullName,
        [string] $language
        )

    # skip if language is not in the supported list
    $lang = CheckLanguageOrUseDefault $language
    if ($lang -ne $language) {
        return
    }

    $enuPath = $fullName.Replace("$localizeRoot\$language", $mainPath)
    if (!(Test-Path $enuPath)) {
        return
    }
    $enuFiles = Get-ChildItem $enuPath

    foreach($enuFile in $enuFiles) {
        $fileName = $enuFile.Name
        $destinationFile = "$fullName\$fileName"
        if (!(Test-Path $destinationFile)) {
            if ($fileName -like "*.workbook") {
                $existingWorkbooks = Get-ChildItem -Path "$fullName\*" -Include *.workbook
                if ($existingWorkbooks.Count -ne 0) {
                    Write-Host ">>>>>> Skipping .workbook in $existingWorkbooks <<<<<<<<"
                    continue
                }    
            }

            $fullPath = $enuFile.FullName
            Write-Host "[#WARNING: missing File]: copying file $fullPath to $fullName"
            # copy file from enu to localized folder
            Copy-Item -Path $fullPath -Destination $fullName
            # check and replace "en-us" with the language for any *.json file
            if (Test-Path $destinationFile -PathType leaf -Include "*.json") {
                $from = """$defaultLanguage"""
                $to = """$language"""
                Write-Host "[#WARNING: missing File]: ...found $destinationFile and replacing $from with $to"
                ((Get-Content -Path $destinationFile -Raw) -replace $from, $to) | Set-Content -Path $destinationFile
            }
        }
    }
}

#----------------------------------------------------------------------------
# CheckLanguageOrUseDefault
#----------------------------------------------------------------------------
Function CheckLanguageOrUseDefault() {
    param(
        [string] $language
    )

    if ($supportedLanguages.Contains($language)) {
        return $language
    } else {
        return $defaultLanguage
    }
}

#----------------------------------------------------------------------------
# BuildingTemplateJson
#----------------------------------------------------------------------------
Function BuildingTemplateJson() {
    param(
        [string] $jsonFileName,
        [string] $language,
        [string] $outputPath
        )

    $currentPath = get-location
    Write-Host ">>>>> Building template json: $jsonFileName in directory $currentPath ..."
    
    $lang = CheckLanguageOrUseDefault $language

    $reports = Get-ChildItem $currentPath
    # initialize the payload
    $payload = @{ }

    foreach ($report in $reports) {
        $reportType = $report.Name

        if ($reportTypes.Contains($reportType)) {

            $payload.$reportType = @{ }

            $categories = Get-ChildItem $report.FullName

            #Add virtual categories
            $virtualCategoriesPath = Join-Path $report.FullName $categoryMetadataFileName 
            if ([System.IO.File]::Exists($virtualCategoriesPath)) {

                AddVirtualCategories $payload.$reportType $virtualCategoriesPath $lang
            }

            foreach ($category in $categories) {

                # Skip if this is the top level categories file (virtual categories), since it was already processed
                if ($category.Name -eq $categoryMetadataFileName) {
                    continue
                }

                $categoryName = $category.Name

                CopyFromEnuIfNotExist $category.FullName $language
                $templates = Get-ChildItem $category.FullName

    
                $categorySettingsPath = Join-Path $category.FullName $categoryMetadataFileName 
                if (![System.IO.File]::Exists($categorySettingsPath)) {
                    # need to use the default language one, why didn't this get copied?
                }

                $categorySettings = Get-Content $categorySettingsPath -Encoding UTF8 | Out-String | ConvertFrom-Json 

                AddCategory $categoryName ($payload.$reportType) $categorySettings $lang

                foreach ($templateFolder in $templates) {
                    
                    if ($templateFolder -is [System.IO.DirectoryInfo]) {
                        CopyFromEnuIfNotExist $templateFolder.FullName $language
                        $templateFiles = Get-ChildItem $templateFolder.FullName
                        $templateMetadata = @{ }
                        $templateMetadata.TemplateByLanguage = @{ }
                        $templateMetadata.Name = $templateFolder.Name

                        # First get template populate template data for default language, which is a top level
                        $templateMetadata.TemplateByLanguage.$lang = GetTemplateContainerData $templateFolder.FullName $language

                        AddTemplatesToVirtualGallery $templateMetadata $language

                        #Then look at any subfolders which correspond to localized data
                        foreach ($templateSubfolders in $templateFiles) {

                            if ($templateSubfolders -is [System.IO.DirectoryInfo]) {                            
                                $templateMetadata.TemplateByLanguage.($templateSubfolders.name) = GetTemplateContainerData $templateSubfolders.FullName $language
                            }
                        }

                        # Add Template container
                        $payload.$reportType.$categoryName.TemplateContainers += $templateMetadata

                    }
                }
            }
        }
    }

    Write-Host "Done building json"

    Write-Host "Copying artifacts"
    $artifactContent = $payload | ConvertTo-Json -depth 10 -Compress

    # create output folder if it doesn't exist
    if (!(Test-Path $outputPath)) {
        mkdir $outputPath
    }

    # delete existing json file
    if (Test-Path "$outputPath\$jsonFileName") {
        Remove-Item "$outputPath\$jsonFileName"
    }

    $artifactContent | Out-File -FilePath "$outputPath\$jsonFileName"
    Write-Host "... DONE building template: $outputPath\$jsonFileName <<<<<"
}

#----------------------------------------------------------------------------
# create the package content for a given language
# produce an "gallery.json" file that contains all of the templates by type/gallery
# produce an "index.json" that is a map of every template id to path
# and a folder of all those templates
#----------------------------------------------------------------------------
Function CreatePackageContent() {
    param(
        [string] $language,
        [string] $outputPath
        )

    $currentPath = get-location
    Write-Host ">>>>> Building package content for $language in directory $currentPath ..."
    

    # create output folder if it doesn't exist
    if (!(Test-Path $outputPath)) {
        mkdir $outputPath
    }

    $packagePath = "$outputPath/package"

    if (!(Test-Path $packagePath)) {
        mkdir $packagePath
    }

    $lang = CheckLanguageOrUseDefault $language

    $reports = Get-ChildItem $currentPath


    # initialize the gallery and index
    $gallery = @{ }
    $index = @{ }

    foreach ($report in $reports) {
        $reportType = $report.Name

        if ($reportTypes.Contains($reportType)) {

            $payload.$reportType = @{ }

            #find all of the categories: any categoryresources.json file is a category
            



            $categories = Get-ChildItem $report.FullName

            #Add virtual categories
            $virtualCategoriesPath = Join-Path $report.FullName $categoryMetadataFileName 
            if ([System.IO.File]::Exists($virtualCategoriesPath)) {

                AddVirtualCategories $payload.$reportType $virtualCategoriesPath $lang
            }

            foreach ($category in $categories) {

                # Skip if this is the top level categories file (virtual categories), since it was already processed
                if ($category.Name -eq $categoryMetadataFileName) {
                    continue
                }

                $categoryName = $category.Name

                CopyFromEnuIfNotExist $category.FullName $language
                $templates = Get-ChildItem $category.FullName

    
                $categorySettingsPath = Join-Path $category.FullName $categoryMetadataFileName 
                if (![System.IO.File]::Exists($categorySettingsPath)) {
                    # need to use the default language one, why didn't this get copied?
                }

                $categorySettings = Get-Content $categorySettingsPath -Encoding UTF8 | Out-String | ConvertFrom-Json 

                AddCategory $categoryName ($payload.$reportType) $categorySettings $lang

                foreach ($templateFolder in $templates) {
                    
                    if ($templateFolder -is [System.IO.DirectoryInfo]) {
                        CopyFromEnuIfNotExist $templateFolder.FullName $language
                        $templateFiles = Get-ChildItem $templateFolder.FullName
                        $templateMetadata = @{ }
                        $templateMetadata.TemplateByLanguage = @{ }
                        $templateMetadata.Name = $templateFolder.Name

                        # First get template populate template data for default language, which is a top level
                        $templateMetadata.TemplateByLanguage.$lang = GetTemplateContainerData $templateFolder.FullName $language $packagePath

                        AddTemplatesToVirtualGallery $templateMetadata $language

                        #Then look at any subfolders which correspond to localized data
                        #foreach ($templateSubfolders in $templateFiles) {
#
 #                           if ($templateSubfolders -is [System.IO.DirectoryInfo]) {
  #                              $templateMetadata.TemplateByLanguage.($templateSubfolders.name) = GetTemplateContainerData $templateSubfolders.FullName $language $packagePath
   #                         }
    #                    }
#
                        # Add Template container
                        $payload.$reportType.$categoryName.TemplateContainers += $templateMetadata

                    }
                }
            }
        }
    }

    Write-Host "Done building gallery"

    Write-Host "Copying artifacts"
    $artifactContent = $payload | ConvertTo-Json -depth 10 -Compress



    $jsonFileName = "gallery.$language.json"
    # delete existing json file
    if (Test-Path "$outputPath\$jsonFileName") {
        Remove-Item "$outputPath\$jsonFileName"
    }

    $artifactContent | Out-File -FilePath "$outputPath\$jsonFileName"
    Write-Host "... DONE building gallery: $outputPath\$jsonFileName <<<<<"
}

#----------------------------------------------------------------------------
# Main
#----------------------------------------------------------------------------
# merge the templates file into a json for each language
#
# community-templates-V2.json:
# Root
#  |- Workbooks (reportFolder)
#        |- Performance (categoryFolder)
#             |- Apdex (templateFolder)
#                 |- en
#                 |   |- settings.json
#                 |   |- readme.md
#                 |   |- Apdex.workbook
#
# community-templates-V2.ko-kr.json:
# Root
#  |- Workbooks (reportFolder)
#        |- Performance (categoryFolder)
#             |- Apdex (templateFolder)
#                 |- ko
#                     |- settings.json
#                     |- readme.md
#                     |- Apdex.workbook        
#----------------------------------------------------------------------------

# pull down all localized repos if run locally
Write-Host "Get Localized Repos"
CloneAndPullLocalizedRepos

# save default path
Push-Location

# process localized repo
foreach ($lang in $supportedLanguages) {
    if ($lang -eq $defaultLanguage) {
        $repoName = $repoBaseName
        $currentPath = $mainPath
    } else {
        $repoName = "$repoBaseName.$lang"
        $currentPath = Convert-Path "$localizeRoot\$lang"
    }
    Set-Location -Path $currentPath
    $jsonFileName = "$azureBlobFileNameBase.$lang.json"

    Write-Host ""
    Write-Host "Processing..."
    Write-Host "...Repo: $repoName"
    Write-Host "...Language: $lang"
    Write-Host "...Directory: $currentPath"
    Write-Host "...OutputFile: $jsonFileName"

    #BuildingTemplateJson $jsonFileName $lang $outputPath
    CreatePackageContent $lang $outputPath
}

# restore default path
Pop-Location

# duplicate json for en-us to be compatible with existing process
Copy-Item -Path $outputPath\$azureBlobFileNameBase.$defaultLanguage.json -Destination $outputPath\$azureBlobFileNameBase.json

Write-Host "Done copying artifacts Existing"
