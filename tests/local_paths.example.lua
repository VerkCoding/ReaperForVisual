-- SPDX-License-Identifier: AGPL-3.0-only
-- Copyright (C) 2026 VerkCoding
--
-- Where the material that is not in the repository lives on your computer. Copy this file to
-- tests/local_paths.lua (git ignores it) and fill in what you have; leave out what you do not.
-- An environment variable of REAPER's wins over this file. A test that needs a path it was not
-- given says so, and skips that part where it can.

return {
  -- RFV_MEDIA: the multitrack the band fixture is cut from (tests/fixtures/band.lua names its files)
  -- media = "C:/Music/Multitracks/Band/Media",

  -- RFV_MEDIA2: Actions, "South Of The Water" from Cambridge-MT's library (tests/fixtures/sotw.lua)
  -- media2 = "C:/Music/Multitracks/Actions_SouthOfTheWater_Full",

  -- RFV_PROJECTS: a folder of real REAPER projects, read as text only (roles_test, snapshot_test)
  -- projects = "C:/Music/Projects",

  -- RFV_SECOND: audio files for axes_second_test, separated by ";"
  -- second = "C:/Music/a.wav;C:/Music/b.wav",
}
