import os
import re

replacements = {
    "l10n.adminLibDisplayTitle": "'Display'",
    "l10n.adminLibDisplaySection": "'Library display'",
    "l10n.adminLibFolderView": "'Display a folder view to show plain media folders'",
    "l10n.adminLibSpecialsInSeasons": "'Display specials within seasons they aired in'",
    "l10n.adminLibGroupMovies": "'Group movies into collections'",
    "l10n.adminLibGroupShows": "'Group shows into collections'",
    "l10n.adminLibExternalSuggestions": "'Show external content in suggestions'",
    "l10n.adminLibDateAddedSection": "'Date added behavior'",
    "l10n.adminLibDateAddedLabel": "'Use date added from'",
    "l10n.adminLibDateAddedImport": "'Date scanned into the library'",
    "l10n.adminLibDateAddedFile": "'Date the file was created'",
    
    "l10n.adminSettingsLoadFailed": "'Failed to load settings'",
    "l10n.adminUnknownError": "'An unknown error occurred'",
    "AppLocalizations.of(context).adminSettingsSaved": "'Settings saved'",
    "l10n.save": "'Save'",
    "l10n.retry": "'Retry'",
    
    "l10n.adminLibMetadataTitle": "'Metadata and Images'",
    "l10n.adminLibMetadataLangSection": "'Preferred metadata language'",
    "l10n.adminLibChaptersSection": "'Chapters'",
    "l10n.adminLibDummyChapterDuration": "'Dummy chapter duration (seconds)'",
    "l10n.adminLibDummyChapterDurationHint": "'Length of chapters generated for media that has none. Set to 0 to disable.'",
    "l10n.adminLibChapterImageResolution": "'Chapter image resolution'",
    "l10n.adminLibChapterImageResolutionMatchSource": "'Match source'",
    "l10n.adminLibChapterImageExtraction": "'Extract chapter images'",
    "l10n.adminLibChapterImagesDuringScan": "'Extract chapter images during the library scan'",
    
    "l10n.adminLibNfoTitle": "'NFO Settings'",
    "l10n.adminLibNfoHelp": "'NFO metadata is compatible with Kodi and similar clients. Settings apply to all libraries that save NFO metadata.'",
    "l10n.adminLibKodiUser": "'User to store watch data for in NFO files'",
    "l10n.adminLibSaveImagePaths": "'Save image paths within NFO files'",
    "l10n.adminLibPathSubstitution": "'Enable path substitution for NFO image paths'",
    "l10n.adminLibExtraThumbs": "'Copy extrafanart images into an extrathumbs folder'",
    "l10n.adminLibNone": "'None'",
    "l10n.adminLibTrickplayExtraction": "'Enable trickplay image extraction'",
    "l10n.adminLibTrickplayDuringScan": "'Extract trickplay images during the library scan'",
    "l10n.adminLibSaveTrickplayWithMedia": "'Save trickplay images into media folders'",
}

files = [
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_display_screen.dart",
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_metadata_screen.dart",
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_nfo_screen.dart"
]

for file in files:
    with open(file, 'r', encoding='utf-8') as f:
        content = f.read()
        
    for k, v in replacements.items():
        content = content.replace(k, v)
            
    # Handle the multiline case for save failed
    content = re.sub(
        r'AppLocalizations\.of\(context\)\s*\.adminSettingsSaveFailed\(e\.toString\(\)\)',
        r"'Failed to save settings: $e'",
        content
    )

    with open(file, 'w', encoding='utf-8') as f:
        f.write(content)

print("Done")
