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
    $defaultLanguage,
    "cs-cz"
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
)
$docGitServer = "https://github.com/MicrosoftDocs/"

#----------------------------------------------------------------------------
# GetTemplateContainerData
#----------------------------------------------------------------------------
Function GetTemplateContainerData() {
    param(
        [String] $templateFolderPath,
        [String] $language
    )   
    
    $templateMetadata = @{ }

    $templateFiles = Get-ChildItem $templateFolderPath

    $hasFoundTemplateContent = $false

    foreach ($templateFile in $templateFiles) {

        if ($templateFile.Name -eq 'settings.json') {
            $templateSettings = Get-Content $templateFile.FullName -Encoding UTF8 | Out-String | ConvertFrom-Json 

            # Build path of file
            $templateFolderName = Split-Path $templateFolderPath -Leaf
            $templateCategoryFolderPath = Split-Path $templateFolderPath
            $templateCategory = Split-Path $templateCategoryFolderPath -Leaf
            $templateReportTypePath = Split-Path $templateCategoryFolderPath
            $templateReportType = Split-Path $templateReportTypePath -Leaf
    
            $templateMetadata.path = "$templateReportType/$templateCategory/$templateFolderName"
            $templateMetadata.name = $templateSettings.name
            $templateMetadata.author = $templateSettings.author
            $templateMetadata.description = $templateSettings.description
            $templateMetadata.tags = $templateSettings.tags
            $templateMetadata.galleries = $templateSettings.galleries
            $templateMetadata.iconUrl = $templateSettings.icon
            $templateMetadata.readme = $templateSettings.readme
            $templateMetadata.isPreview = $templateSettings.isPreview
        }
        elseif ($templateExtensions.Contains($templateFile.Name.split(".")[-1])) {

            if ($hasFoundTemplateContent) {
                throw "There cannot be more than one content file per template $templateFolderPath"
            }

            $hasFoundTemplateContent = $true

            # This is the template content for default language
            $templateMetadata.Content = Get-Content $templateFile.FullName -Encoding UTF8 | Out-String

        }
    }

    if ( $null -eq $templateMetadata.path -or $null -eq $templateMetadata.Content) {
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

    Write-Host "Adding virtual caregories from $categoriesMetadataFilepath"

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
            git clone --single-branch --branch master --no-tags "$docGitServer$repoName.git" $lang
        }
    }
    Pop-Location
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
                $templates = Get-ChildItem $category.FullName

    
                $categorySettingsPath = Join-Path $category.FullName $categoryMetadataFileName 
                if (![System.IO.File]::Exists($categorySettingsPath)) {
                    # need to use the default language one, why didn't this get copied?
                }

                $categorySettings = Get-Content $categorySettingsPath -Encoding UTF8 | Out-String | ConvertFrom-Json 

                AddCategory $categoryName ($payload.$reportType) $categorySettings $lang

                foreach ($templateFolder in $templates) {
                    
                    if ($templateFolder -is [System.IO.DirectoryInfo]) {
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

    # find all the important files
    $files = Get-ChildItem "$sourcePath\$reporttype" -Recurse -file -Include "categoryresources.json", "*.workbook", "*.cohort", "settings.json", "*.svg"

    $reports = Get-ChildItem $currentPath


    # initialize the gallery and index
    $gallery = @{ }
    $index = @{ }

    foreach ($report in $reports) {
        $reportType = $report.Name

        if ($reportTypes.Contains($reportType)) {

            $payload.$reportType = @{ }

            #find all of the categories: any categoryresources.json file is a virtual category
            # i think this part doesn' twork right for loc though?
            $categories = Get-ChildItem $report.FullName -Include $categoryMetadataFileName -recurse
            foreach ($category in $categories) {
                AddVirtualCategories $payload.$reportType $category.FullName $lang
            }

            # now process all folders that could be categories themselves
            $categories = Get-ChildItem $report.FullName -Exclude $categoryMetadataFileName

            foreach ($category in $categories) {

                $categoryName = $category.Name
                $templates = Get-ChildItem $category.FullName
    
                $categorySettingsPath = Join-Path $category.FullName $categoryMetadataFileName 
                $categorySettings = Get-Content $categorySettingsPath -Encoding UTF8 | Out-String | ConvertFrom-Json 

                AddCategory $categoryName ($payload.$reportType) $categorySettings $lang

                foreach ($templateFolder in $templates) {
                    
                    if ($templateFolder -is [System.IO.DirectoryInfo]) {
                        $templateFiles = Get-ChildItem $templateFolder.FullName
                        $templateMetadata = @{ }
                        $templateMetadata.TemplateByLanguage = @{ }
                        $templateMetadata.Name = $templateFolder.Name

                        # First get template populate template data for default language, which is a top level
                        $templateMetadata.TemplateByLanguage.$lang = GetTemplateContainerData $templateFolder.FullName $language $packagePath

                        AddTemplatesToVirtualGallery $templateMetadata $language

                        #Then look at any subfolders which correspond to localized data
                        #this is theoretically how non-microsoft content gets localized?
                        foreach ($templateSubfolders in $templateFiles) {

                           if ($templateSubfolders -is [System.IO.DirectoryInfo]) {
                               $templateMetadata.TemplateByLanguage.($templateSubfolders.name) = GetTemplateContainerData $templateSubfolders.FullName $language $packagePath
                          }
                        }

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

# ------------------------------
# for the language provided, make sure all the important files from the source path are accounted for in the language folder
# ------------------------------
Function SyncWithEnUs() {
    param(
        [string] $sourcePath,
        [string] $lang
        )

    # find all the important files: **/categoryResources.json, *.workbook, *.cohort, **/settings.json, and any svg images
    # in the source path, and make sure they exist in the specific language's path
    $created = 0;
    $total = 0
    foreach ($reportType in $reportTypes) {
        $files = Get-ChildItem "$sourcePath\$reporttype" -Recurse -file -Include "categoryresources.json", "*.workbook", "*.cohort", "settings.json", "*.svg"
        $total += $files.Count
        foreach ($file in $files) {
            $fullpath = $file.FullName
            $scriptpath = $fullpath.Replace("$sourcePath\$reporttype", "$sourcePath\scripts\$lang\$reporttype")
            if (![System.IO.File]::Exists($scriptpath)) {
                Write-Host "[#WARNING: missing File]: copying file $fullPath to $scriptpath"
                # use newitem force to create the full path structure if it doesn't exist
                if (!(Test-Path (Split-Path -Path $scriptpath))) {
                    New-Item -ItemType File -Path $scriptpath -Force
                }
                Copy-Item -Path $fullPath -Destination $scriptpath
                $created++
            }
        }
    }
    Write-Host "WARNING: $lang - copied $created missing files of $total"
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
# en-us gets done first so that the content is there to sync up with all the other languages
foreach ($lang in $supportedLanguages) {
    if ($lang -eq $defaultLanguage) {
        $repoName = $repoBaseName
        $currentPath = $mainPath
    } else {
        $repoName = "$repoBaseName.$lang"
        $currentPath = Convert-Path "$localizeRoot\$lang"
        SyncWithEnUs $mainPath $lang
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
    #CreatePackageContent $lang $outputPath
}

# restore default path
Pop-Location

# duplicate json for en-us to be compatible with existing process
Copy-Item -Path $outputPath\$azureBlobFileNameBase.$defaultLanguage.json -Destination $outputPath\$azureBlobFileNameBase.json

Write-Host "Done copying artifacts Existing"
