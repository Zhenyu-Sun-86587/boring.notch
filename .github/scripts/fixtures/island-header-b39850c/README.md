These three files are unchanged copies of `BoringHeader.swift`, `TabSelectionView.swift`,
and `TabButton.swift` from commit `b39850cb5c3628fc9ce6f07205345dfa48c65da3`.

`test_island_components.py` compiles this frozen baseline and the current production
components separately. It strips editor previews and adds the same passive background
frame marker to the real SF Image in both versions. It uses no network or Git history
at test time, including a shallow CI checkout.

The passive fixture pages are deliberately colored so composited old/new page overlap
can be measured against settled frames. They are not real Hermes conversations, user
clipboard contents, media, or Shelf files. Tests do not replace real UI acceptance.
