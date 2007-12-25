# GNUmakefile
#
# Builds MacTelnet's application bundle by running each project
# (in all required configurations) and copying the resulting
# components into place.
#
# This is necessary to manage such things as merging multiple
# architectures/versions of Quills.framework, and installation
# of secondary executables such as the bug reporter.
#
# Kevin Grant (kevin@ieee.org)
# December 14, 2007

.PHONY: help
help:
	@echo "Usage: make [FOR_PANTHER=no] [FOR_TIGER=no] debug"
	@echo "       make clean"
	@echo
	@echo "You can also request specific component rules;"
	@echo "look in the GNUmakefile to see what is defined."
	@echo "These may save you some time."
	@echo
	@echo "Finally, note that many components are built using"
	@echo "Xcode, so you can often use the GUI instead.  But"
	@echo "you still need to run this makefile when ready to"
	@echo "assemble the final application bundle."
	@echo

# tools
COPY=/bin/cp
MKDIR_P=/usr/bin/install -d
RMDIR=/bin/rmdir
RSYNC=/usr/bin/rsync
SYMLINK_REPLACE=/bin/ln -snf
XARGS=/usr/bin/xargs
XCB=/usr/bin/xcodebuild

# set this to "no" if you want to disable Panther support (may
# make MacTelnet easier to build if you don't care about 10.3);
# e.g. "make FOR_PANTHER=no ..."
FOR_PANTHER=yes

# set this to "no" if you want to disable Tiger support (may
# make MacTelnet easier to build if you don't care about 10.4);
# e.g. "make FOR_TIGER=no ..."
FOR_TIGER=yes

# the PyMacTelnet.framework target is platform-independent, but
# an arbitrary configuration must be given to have Xcode build it
# (and decide the output directory from which to copy)
PY_CONFIG := ForLeopardDebug

SRC_APP_PROJ_TOP := $(CURDIR)/Application
SRC_BUGREPORTER_PROJ_TOP := $(CURDIR)/BugReporter
SRC_PREFSCONVERTER_PROJ_TOP := $(CURDIR)/PrefsConverter

SRC_APP_BUILD_TOP_LEOPARD := $(SRC_APP_PROJ_TOP)/ForLeopardDebug
SRC_APP_BUILD_TOP_TIGER := $(SRC_APP_PROJ_TOP)/ForTigerDebug
SRC_APP_BUILD_TOP_PANTHER := $(SRC_APP_PROJ_TOP)/ForPantherDebug
SRC_APP_PYCODE_TOP := $(SRC_APP_PROJ_TOP)/PythonCode
SRC_APP_RESOURCES_TOP := $(SRC_APP_PROJ_TOP)/Resources
SRC_BUGREPORTER_TOP := $(SRC_BUGREPORTER_PROJ_TOP)/ForDebugging/BugReporter.app
SRC_PREFSCONVERTER_TOP := $(SRC_PREFSCONVERTER_PROJ_TOP)/ForDebugging/PrefsConverter.app
SRC_PY_TOP := $(SRC_APP_PROJ_TOP)/$(PY_CONFIG)/PyMacTelnet.framework
SRC_QUILLS_TOP_TIGER := $(SRC_APP_BUILD_TOP_TIGER)/Quills.framework
SRC_QUILLS_TOP_PANTHER := $(SRC_APP_BUILD_TOP_PANTHER)/Quills.framework
SRC_SWIG_TOP_LEOPARD := $(SRC_APP_BUILD_TOP_LEOPARD)
SRC_SWIG_TOP_TIGER := $(SRC_APP_BUILD_TOP_TIGER)
SRC_SWIG_TOP_PANTHER := $(SRC_APP_BUILD_TOP_PANTHER)

DEST_APP_TOP := $(CURDIR)/MacTelnet.app/Contents
DEST_APP_FW_TOP := $(DEST_APP_TOP)/Frameworks
DEST_APP_MACOS_TOP := $(DEST_APP_TOP)/MacOS
DEST_APP_RESOURCES_TOP := $(DEST_APP_TOP)/Resources
DEST_BUGREPORTER_TOP := $(DEST_APP_RESOURCES_TOP)/BugReporter.app
DEST_PREFSCONVERTER_TOP := $(DEST_APP_RESOURCES_TOP)/PrefsConverter.app
DEST_PY_TOP := $(DEST_APP_FW_TOP)/PyMacTelnet.framework
DEST_QUILLS_TOP := $(DEST_APP_FW_TOP)/Quills.framework
DEST_SWIG_TOP_LEOPARD := $(DEST_QUILLS_TOP)/Versions/B/lib/python2.5
DEST_SWIG_TOP_TIGER := $(DEST_QUILLS_TOP)/Versions/B/lib/python2.3.5
DEST_SWIG_TOP_PANTHER := $(DEST_QUILLS_TOP)/Versions/A/lib/python2.3

SWIG_WRAPPERS := _Quills.so Quills.py

PANTHER_SWIG_WRAPPERS :=
ifeq ($(strip $(FOR_PANTHER)),yes)
PANTHER_SWIG_WRAPPERS := $(addprefix $(DEST_SWIG_TOP_PANTHER)/,$(SWIG_WRAPPERS))
endif

TIGER_SWIG_WRAPPERS :=
ifeq ($(strip $(FOR_TIGER)),yes)
TIGER_SWIG_WRAPPERS := $(addprefix $(DEST_SWIG_TOP_TIGER)/,$(SWIG_WRAPPERS))
endif

LEOPARD_SWIG_WRAPPERS := $(addprefix $(DEST_SWIG_TOP_LEOPARD)/,$(SWIG_WRAPPERS))

# the resource list is broken into types (files or
# bundles) for convenience when writing rules that
# need different commands for recursive trees
APP_RESOURCES_FILES := \
DefaultPreferences.plist \
IconForBellOff.icns \
IconForBellOn.icns \
IconForBundle.icns \
IconForCommand.icns \
IconForContextMenu.icns \
IconForHide.icns \
IconForItemAdd.icns \
IconForItemRemove.icns \
IconForKeypadArrowDown.icns \
IconForKeypadArrowLeft.icns \
IconForKeypadArrowRight.icns \
IconForKeypadArrowUp.icns \
IconForKeypadDelete.icns \
IconForKeypadEnter.icns \
IconForKeypadFind.icns \
IconForKeypadInsert.icns \
IconForKeypadPageDown.icns \
IconForKeypadPageUp.icns \
IconForKeypadSelect.icns \
IconForLEDOff.icns \
IconForLEDOn.icns \
IconForMacroSet.icns \
IconForPrefPanelFormats.icns \
IconForPrefPanelGeneral.icns \
IconForPrefPanelKiosk.icns \
IconForPrefPanelMacros.icns \
IconForPrefPanelScripts.icns \
IconForPrefPanelSessions.icns \
IconForPrefPanelTerminals.icns \
IconForPrefPanelTranslations.icns \
IconForPreferenceCollections.icns \
IconForScriptsMenu.icns \
IconForScrollLockOff.icns \
IconForScrollLockOn.icns \
IconForSession.icns \
IconForSessionStatusActive.icns \
IconForSessionStatusDead.icns \
IconForStackWindows.icns \
IconForTerminal.icns \
English.lproj/DockTileAttention.pict \
English.lproj/DockTileAttentionMask.pict \
English.lproj/SplashScreen.pict
APP_RESOURCES_BUNDLES := \
MacTelnet.help \
English.lproj/AboutBox.nib \
English.lproj/AddressDialog.nib \
English.lproj/AlertMessages.nib \
English.lproj/Clipboard.nib \
English.lproj/ColorBox.nib \
English.lproj/CommandLine.nib \
English.lproj/DuplicateDialog.nib \
English.lproj/FindDialog.nib \
English.lproj/GenericDialog.nib \
English.lproj/InfoWindow.nib \
English.lproj/Keypads.nib \
English.lproj/KioskDisableFloater.nib \
English.lproj/KioskPasswordDialog.nib \
English.lproj/MacroSetupWindow.nib \
English.lproj/MainMenuHelp.nib \
English.lproj/MainMenus.nib \
English.lproj/MenuForDockIcon.nib \
English.lproj/PrefPanelFormats.nib \
English.lproj/PrefPanelMacros.nib \
English.lproj/PrefPanels.nib \
English.lproj/PrefPanelSessions.nib \
English.lproj/PrefPanelTerminals.nib \
English.lproj/PrefsWindow.nib \
English.lproj/ProgressDialog.nib \
English.lproj/SizeDialog.nib \
English.lproj/TEKWindow.nib \
English.lproj/TerminalWindow.nib \
English.lproj/WindowTitleDialog.nib
APP_RESOURCES := \
$(APP_RESOURCES_FILES) \
$(APP_RESOURCES_BUNDLES) \

# reinstalls application resources when they change;
# note that the trailing slash is significant for
# rsyncing directories in order to copy what's in them
# and not create a redundant destination directory
$(DEST_APP_RESOURCES_TOP)/%: $(SRC_APP_RESOURCES_TOP)/%
	$(MKDIR_P) $(dir $@)
	@if [ -d "$^" ] ; then \
		$(RSYNC) --archive --exclude=.svn/ $^/ $@ ; \
	else \
		$(RSYNC) --archive --exclude=.svn/ $^ $@ ; \
	fi

#
# Frameworks subdirectory
#

# Component: Quills.framework

.PHONY: install-quills-framework
install-quills-framework:
	@# keep in sync with the matching clean rule
	@#-
	@# it is only necessary to build the code once per architecture,
	@# which the Tiger build handles; however, a (PPC-only) Panther
	@# build is done because 10.3 doesn't support universal binaries
ifeq ($(strip $(FOR_PANTHER)),yes)
	$(XCB) -project Application.xcodeproj -target Quills.framework -configuration ForPantherDebug
endif
	@# Tiger and Leopard share this configuration...
	$(XCB) -project Application.xcodeproj -target Quills.framework -configuration ForTigerDebug
	@# merge in the built frameworks to one root; start with the
	@# "preferred" version so that the framework structure
	@# generated by Xcode is already basically set up
	$(RSYNC) --archive $(SRC_QUILLS_TOP_TIGER)/ $(DEST_QUILLS_TOP)
	$(MKDIR_P) $(DEST_QUILLS_TOP)/Versions/A
	$(RSYNC) --archive $(SRC_QUILLS_TOP_PANTHER)/Versions/A/ $(DEST_QUILLS_TOP)/Versions/A
	@# add remaining parts
	$(MAKE) install-swig-wrappers
	$(SYMLINK_REPLACE) Versions/B/Resources $(DEST_QUILLS_TOP)/

.PHONY: clean-quills-framework
clean-quills-framework:
	$(MAKE) clean-swig-wrappers
	$(XCB) clean -project Application.xcodeproj -target PythonWrapper -configuration ForLeopardDebug
ifeq ($(strip $(FOR_PANTHER)),yes)
	$(XCB) clean -project Application.xcodeproj -target PythonWrapper -configuration ForPantherDebug
	$(XCB) clean -project Application.xcodeproj -target Quills.framework -configuration ForPantherDebug
endif
ifeq ($(strip $(FOR_TIGER)),yes)
	$(XCB) clean -project Application.xcodeproj -target PythonWrapper -configuration ForTigerDebug
endif
	@# note: the majority of Quills isn't built specifically for Leopard,
	@# so the Tiger clean applies to both Tiger and Leopard
	$(XCB) clean -project Application.xcodeproj -target Quills.framework -configuration ForTigerDebug
	-$(RMDIR) $(DEST_QUILLS_TOP)

# reinstalls a SWIG wrapper when it changes
$(DEST_SWIG_TOP_PANTHER)/%: $(SRC_APP_BUILD_TOP_PANTHER)/%
	$(XCB) -project Application.xcodeproj -target PythonWrapper -configuration ForPantherDebug
	$(MKDIR_P) $(dir $@)
	$(COPY) $^ $@

# reinstalls a SWIG wrapper when it changes
$(DEST_SWIG_TOP_TIGER)/%: $(SRC_APP_BUILD_TOP_TIGER)/%
	$(XCB) -project Application.xcodeproj -target PythonWrapper -configuration ForTigerDebug
	$(MKDIR_P) $(dir $@)
	$(COPY) $^ $@

# reinstalls a SWIG wrapper when it changes
$(DEST_SWIG_TOP_LEOPARD)/%: $(SRC_APP_BUILD_TOP_LEOPARD)/%
	@# Python versions are different on each Mac OS, so the lightweight
	@# SWIG wrapper code *does* have to be compiled for each separately
	$(XCB) -project Application.xcodeproj -target PythonWrapper -configuration ForLeopardDebug
	$(MKDIR_P) $(dir $@)
	$(COPY) $^ $@

.PHONY: install-swig-wrappers
install-swig-wrappers: \
$(PANTHER_SWIG_WRAPPERS) \
$(TIGER_SWIG_WRAPPERS) \
$(LEOPARD_SWIG_WRAPPERS)
	@echo

.PHONY: clean-swig-wrappers
clean-swig-wrappers:
	echo '$(PANTHER_SWIG_WRAPPERS)' | $(XARGS) $(RM)
	-$(RMDIR) $(DEST_SWIG_TOP_PANTHER)
	echo '$(TIGER_SWIG_WRAPPERS)' | $(XARGS) $(RM)
	-$(RMDIR) $(DEST_SWIG_TOP_TIGER)
	echo '$(LEOPARD_SWIG_WRAPPERS)' | $(XARGS) $(RM)
	-$(RMDIR) $(DEST_SWIG_TOP_LEOPARD)
	@echo

# Component: PyMacTelnet.framework

.PHONY: install-py-framework
install-py-framework:
	@# keep in sync with the matching clean rule
	$(XCB) -project Application.xcodeproj -target PyMacTelnet.framework -configuration $(PY_CONFIG)
	@# avoid rsyncing from /
	@if [ "x$(SRC_PY_TOP)" = "x" ] ; then \
		echo "SRC_PY_TOP variable unset" >&2 ; \
		exit 1 ; \
	fi
	$(MKDIR_P) $(dir $(DEST_PY_TOP))
	$(RSYNC) --archive $(SRC_PY_TOP)/ $(DEST_PY_TOP)

.PHONY: clean-py-framework
clean-py-framework:
	$(XCB) clean -project Application.xcodeproj -target PyMacTelnet.framework -configuration $(PY_CONFIG)
	-$(RMDIR) $(DEST_PY_TOP)

# Composite: Frameworks

.PHONY: install-frameworks
install-frameworks: \
install-py-framework \
install-quills-framework
	@# keep in sync with the matching clean rule
	@echo

.PHONY: clean-frameworks
clean-frameworks: \
clean-quills-framework \
clean-py-framework
	-$(RMDIR) $(DEST_APP_FW_TOP)

#
# MacOS subdirectory
#

# reinstalls Python programs when their code changes
$(DEST_APP_MACOS_TOP)/%: $(SRC_APP_PYCODE_TOP)/%
	$(MKDIR_P) $(dir $@)
	$(COPY) $^ $@

# The "MacOS/MacTelnet" (main) executable in the bundle
# looks for a "python" executable in the same place.
# This script sets up that link.
#
# IMPORTANT: This MUST be a link, Python MUST run from
# a path WITHIN THE BUNDLE.  If it does not, Mac OS X
# thinks Python is the core executable and uses the
# Python bundle instead (e.g. setting the name of the
# application menu to Python, and worse!).
#
.PHONY: install-executables
install-executables: \
$(DEST_APP_MACOS_TOP)/MacTelnet \
$(DEST_APP_MACOS_TOP)/RunMacTelnet.py
	@# keep in sync with the matching clean rule
	$(MKDIR_P) $(DEST_APP_MACOS_TOP)
	$(SYMLINK_REPLACE) /usr/bin/python $(DEST_APP_MACOS_TOP)/

.PHONY: clean-executables
clean-executables:
	$(RM) $(DEST_APP_MACOS_TOP)/MacTelnet
	$(RM) $(DEST_APP_MACOS_TOP)/RunMacTelnet.py
	$(RM) $(DEST_APP_MACOS_TOP)/python
	-$(RMDIR) $(DEST_APP_MACOS_TOP)

#
# Resources subdirectory
#

# Component: Localized .strings Files

.PHONY: install-app-dot-strings
install-app-dot-strings: $(SRC_APP_PROJ_TOP)/Code/UIStrings.cp
	@# keep in sync with the matching clean rule
	$(MKDIR_P) $(DEST_APP_RESOURCES_TOP)/English.lproj
	/usr/bin/genstrings $(SRC_APP_PROJ_TOP)/Code/UIStrings.cp -o $(DEST_APP_RESOURCES_TOP)/English.lproj

.PHONY: clean-app-dot-strings
clean-app-dot-strings:
	$(foreach FILE,$(wildcard $(DEST_APP_RESOURCES_TOP)/English.lproj/*.strings),$(RM) $(FILE) ;)

# Component: MacTelnet Help

$(DEST_APP_RESOURCES_TOP)/MacTelnet.help:
	$(CURDIR)/HTMLHelpBuild.command
	$(MKDIR_P) $(dir $@)
	$(RSYNC) --archive $(CURDIR)/HTMLHelp/MacTelnet.help/ $@

# Component: Bug Reporter

.PHONY: install-bug-reporter
install-bug-reporter:
	@# keep in sync with the matching clean rule
	$(XCB) -project BugReporter.xcodeproj
	@# avoid rsyncing from /
	@if [ "x$(SRC_BUGREPORTER_TOP)" = "x" ] ; then \
		echo "SRC_BUGREPORTER_TOP variable unset" >&2 ; \
		exit 1 ; \
	fi
	$(MKDIR_P) $(dir $(DEST_BUGREPORTER_TOP))
	$(RSYNC) --archive $(SRC_BUGREPORTER_TOP)/ $(DEST_BUGREPORTER_TOP)

.PHONY: clean-bug-reporter
clean-bug-reporter:
	$(XCB) clean -project BugReporter.xcodeproj
	$(RM) -R $(DEST_BUGREPORTER_TOP)

# Component: Preferences Converter

.PHONY: install-prefs-converter
install-prefs-converter:
	@# keep in sync with the matching clean rule
	$(XCB) -project PrefsConverter.xcodeproj
	@# avoid rsyncing from /
	@if [ "x$(SRC_PREFSCONVERTER_TOP)" = "x" ] ; then \
		echo "SRC_PREFSCONVERTER_TOP variable unset" >&2 ; \
		exit 1 ; \
	fi
	$(MKDIR_P) $(dir $(DEST_PREFSCONVERTER_TOP))
	$(RSYNC) --archive $(SRC_PREFSCONVERTER_TOP)/ $(DEST_PREFSCONVERTER_TOP)

.PHONY: clean-prefs-converter
clean-prefs-converter:
	$(XCB) clean -project PrefsConverter.xcodeproj
	$(RM) -R $(DEST_PREFSCONVERTER_TOP)

# Component: Miscellaneous Resources (NIBs, Images, etc.)

.PHONY: install-resources
install-resources: \
$(addprefix $(DEST_APP_RESOURCES_TOP)/,$(APP_RESOURCES))
	@# keep in sync with the matching clean rule
	$(MKDIR_P) $(DEST_APP_RESOURCES_TOP)/English.lproj
	$(MAKE) install-app-dot-strings
	$(MAKE) install-bug-reporter
	$(MAKE) install-prefs-converter

.PHONY: clean-resources
clean-resources:
	echo '$(addprefix $(DEST_APP_RESOURCES_TOP)/,$(APP_RESOURCES_FILES))' | $(XARGS) $(RM)
	echo '$(addprefix $(DEST_APP_RESOURCES_TOP)/,$(APP_RESOURCES_BUNDLES))' | $(XARGS) $(RM) -R
	$(MAKE) clean-prefs-converter
	$(MAKE) clean-bug-reporter
	$(MAKE) clean-app-dot-strings
	-$(RMDIR) $(DEST_APP_RESOURCES_TOP)/English.lproj
	-$(RMDIR) $(DEST_APP_RESOURCES_TOP)

#
# Info.plist file
#

$(DEST_APP_TOP)/Info.plist:
	$(MKDIR_P) $(dir $@)
	@# this is always regenerated because it changes daily and is a tiny file
	$(COPY) $(SRC_APP_RESOURCES_TOP)/Template-MacTelnet-Info.plist $@
	env BUILT_PRODUCTS_DIR="$(DEST_APP_TOP)" INFOPLIST_PATH=Info.plist \
		$(CURDIR)/VersionInfo.sh $(CURDIR)/Tools/AutoDatePropertyList.sh

#
# Primary Rules
#

.PHONY: debug
debug:
	@# just comment-out anything you don't care about; MacTelnet
	@# still works with most of its components missing
	$(MAKE) $(DEST_APP_TOP)/Info.plist
	$(MAKE) install-frameworks
	$(MAKE) install-executables
	$(MAKE) install-resources
	@echo "Build complete."

.PHONY: clean
clean:
	$(MAKE) clean-resources
	$(MAKE) clean-executables
	$(MAKE) clean-frameworks
	-$(RMDIR) $(SRC_APP_BUILD_TOP_LEOPARD)
	-$(RMDIR) $(SRC_APP_BUILD_TOP_TIGER)
	-$(RMDIR) $(SRC_APP_BUILD_TOP_PANTHER)
	$(RM) $(DEST_APP_TOP)/Info.plist
	-$(RMDIR) $(DEST_APP_TOP)
	-$(RMDIR) $(dir $(DEST_APP_TOP))
	@echo "Clean complete."
