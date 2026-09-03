# Dictation trailing space plan

1. Add a persisted Boolean setting with an off default and legacy decoding coverage.
2. Write a failing DictationController test proving enabled direct dictation inserts one trailing space while history stays normalized.
3. Apply the setting only at the direct insertion boundary.
4. Add the General settings toggle and update smoke coverage and changelog.
5. Run focused tests, full suites, generate the Xcode project, build, and install the signed app.
