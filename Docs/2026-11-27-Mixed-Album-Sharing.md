# Mixed photo and video sharing

The user requested removal of the App's mandatory media split. Tapping Share now sends all selected readable photo/video originals to the existing iOS share sheet in album order. The App no longer presents the forced "Share Photos and Videos Separately" dialog.

For mixed selections, touching and holding Share offers localized Photos Only and Videos Only context-menu actions. Each action recalculates the current selection and validates its files; no cached URL batch is retained. Selection remains intact after sharing or dismissing the share sheet so another subset can be sent without selecting again. The button includes a bilingual accessibility hint describing the optional context menu.

The existing image providers, media item sources, system share diagnostics and completion callbacks remain unchanged. Whether a particular receiver accepts mixed items remains determined by its share extension; this change removes only the App-side restriction.

Local verification: Swift parsing, scoped layout scan and Git whitespace checks pass. Source inspection confirms default-all sharing, subset filtering, readable-file guards, retained selection and unchanged system-share implementation. No new native tests were added for this reversible UI/routing adjustment. iOS presentation and recipient delivery remain pending requested packaging/device testing. Version remains 1.1.7 (187); no package or cloud task was started.
