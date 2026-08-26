import os

files = [
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_metadata_screen.dart",
]

with open(files[0], 'r', encoding='utf-8') as f:
    c = f.read()

c = c.replace("l10n.adminGeneralMetadataLanguage", "'Preferred metadata language'")
c = c.replace("l10n.adminGeneralMetadataCountry", "'Preferred metadata country'")

with open(files[0], 'w', encoding='utf-8') as f:
    f.write(c)

print("Fixed more l10n")
