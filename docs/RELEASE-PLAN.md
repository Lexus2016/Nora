# Nora: next-release acceptance plan

## Localization expansion (planned, not yet implemented)

The target is eleven interface languages: English (`en`), Simplified Chinese
(`zh-Hans`), Traditional Chinese (`zh-Hant`), Japanese (`ja`), Korean (`ko`),
German (`de`), French (`fr`), Ukrainian (`uk`), Russian (`ru`), Spanish (`es`), and Portuguese (`pt`).

The current implementation and native visual checks cover English, Ukrainian,
and Russian. The other eight languages are planned work, not a claim of shipped
support and not a blocker for the current safety-fix branch.

Acceptance for each added language:

- Translate the complete compiler-extracted catalog: navigation, onboarding,
  errors, recovery, tooltips, help, notifications, Trash reminder and irreversible
  confirmation, and separate ClamAV engine/signature management.
- Verify locale-aware numbers, dates, sizes, plural forms, and appropriate CJK
  font fallback. No English-only interpolated sentence fragments.
- Run the native app and screenshot suite with the process language selected,
  including minimum supported window sizes, long error messages, empty/loading/
  failed/partial/completed states, keyboard focus, and accessibility labels.
- Review clipping, line wrapping, button reachability, and font legibility with
  language-proficient reviewers; fixture screenshots do not prove live interaction.
- Define and test a clear English fallback for missing or unsupported translations.
- Preserve backend command protocol parsing. Do not translate raw CLI output or
  use UI-localized strings to recognize safety confirmations. Test supported
  backend output locales explicitly with unchanged/changed selection fixtures.

Mole README translations are documentation coverage, not proof that its runtime
output or Nora's confirmation parser supports those locales. Backend compatibility
must be established independently before destructive actions are enabled.

Spanish and Portuguese start with a neutral language baseline. Separate regional
translations have not been selected or promised; locale-dependent formatting must
still respect the user’s region.
