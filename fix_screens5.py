import os
import re

files = [
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_display_screen.dart",
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_metadata_screen.dart",
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_nfo_screen.dart"
]

for file in files:
    with open(file, 'r', encoding='utf-8') as f:
        c = f.read()
    
    c = re.sub(r'final l10n = AppLocalizations\.of\(context\);\s*', '', c)
    c = re.sub(r"import '../../../../l10n/app_localizations\.dart';\s*", '', c)
    
    with open(file, 'w', encoding='utf-8') as f:
        f.write(c)

print("Removed l10n variables")
