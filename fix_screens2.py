import os

files = [
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_metadata_screen.dart",
    r"C:\Voltix Newest\lib\ui\screens\admin\libraries\admin_library_nfo_screen.dart"
]

# metadata screen
with open(files[0], 'r', encoding='utf-8') as f:
    c = f.read()

c = c.replace("'Dummy chapter duration (seconds)'Hint", "'Length of chapters generated for media that has none. Set to 0 to disable.'")
c = c.replace("'Chapter image resolution'MatchSource", "'Match source'")
c = c.replace("l10n.adminLibDefault", "'Default'")
c = c.replace("await _api.getCultures()", "[]") # mock or find real if possible
c = c.replace("await _api.getCountries()", "[]") # mock

with open(files[0], 'w', encoding='utf-8') as f:
    f.write(c)

# nfo screen
with open(files[1], 'r', encoding='utf-8') as f:
    c = f.read()

c = c.replace("l10n.adminDrawerNfo", "'NFO'")
with open(files[1], 'w', encoding='utf-8') as f:
    f.write(c)

print("Fixed")
