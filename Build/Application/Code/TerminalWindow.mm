/*!	\file TerminalWindow.mm
	\brief The most common type of window, used to hold
	terminal views and scroll bars for a session.
	
	Note that this is in transition from Carbon to Cocoa,
	and is not yet taking advantage of most of Cocoa.
*/
/*###############################################################

	MacTerm
		© 1998-2017 by Kevin Grant.
		© 2001-2003 by Ian Anderson.
		© 1986-1994 University of Illinois Board of Trustees
		(see About box for full list of U of I contributors).
	
	This program is free software; you can redistribute it or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version
	2 of the License, or (at your option) any later version.
	
	This program is distributed in the hope that it will be
	useful, but WITHOUT ANY WARRANTY; without even the implied
	warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
	PURPOSE.  See the GNU General Public License for more
	details.
	
	You should have received a copy of the GNU General Public
	License along with this program; if not, write to:
	
		Free Software Foundation, Inc.
		59 Temple Place, Suite 330
		Boston, MA  02111-1307
		USA

###############################################################*/

#import "TerminalWindow.h"
#import <UniversalDefines.h>

// standard-C includes
#import <cstring>

// standard-C++ includes
#import <algorithm>
#import <map>
#import <vector>

// UNIX includes
extern "C"
{
#	include <pthread.h>
#	include <strings.h>
}

// Mac includes
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>

// library includes
#import <AlertMessages.h>
#import <CarbonEventHandlerWrap.template.h>
#import <CarbonEventUtilities.template.h>
#import <CFRetainRelease.h>
#import <CGContextSaveRestore.h>
#import <CocoaAnimation.h>
#import <CocoaBasic.h>
#import <CocoaExtensions.objc++.h>
#import <CocoaFuture.objc++.h>
#import <ColorUtilities.h>
#import <CommonEventHandlers.h>
#import <Console.h>
#import <ContextSensitiveMenu.h>
#import <HIViewWrap.h>
#import <HIViewWrapManip.h>
#import <Localization.h>
#import <MemoryBlockPtrLocker.template.h>
#import <MemoryBlockReferenceTracker.template.h>
#import <MemoryBlocks.h>
#import <NIBLoader.h>
#import <RandomWrap.h>
#import <RegionUtilities.h>
#import <Registrar.template.h>
#import <SoundSystem.h>
#import <Undoables.h>

// application includes
#import "AppResources.h"
#import "Commands.h"
#import "DialogUtilities.h"
#import "EventLoop.h"
#import "FindDialog.h"
#import "GenericDialog.h"
#import "HelpSystem.h"
#import "Keypads.h"
#import "Preferences.h"
#import "PrefPanelFormats.h"
#import "PrefPanelTerminals.h"
#import "PrefPanelTranslations.h"
#import "SessionFactory.h"
#import "Terminal.h"
#import "TerminalToolbar.objc++.h"
#import "TerminalView.h"
#import "UIStrings.h"



#pragma mark Constants
namespace {

/*!
Named flags, for clarity in the methods that use them.
*/
enum My_FullScreenState : UInt8
{
	kMy_FullScreenStateCompleted	= true,
	kMy_FullScreenStateInProgress	= false
};

/*!
These are hacks.  But they make up for the fact that theme
APIs do not really work very well at all, and it is
necessary in a few places to figure out how much space is
occupied by certain parts of a scroll bar.
*/
float const		kMy_ScrollBarThumbEndCapSize = 16.0; // pixels
float const		kMy_ScrollBarThumbMinimumSize = kMy_ScrollBarThumbEndCapSize + 32.0 + kMy_ScrollBarThumbEndCapSize; // pixels
float const		kMy_ScrollBarArrowHeight = 16.0; // pixels

/*!
Use with getScrollBarKind() for an unknown scroll bar.
*/
enum My_ScrollBarKind
{
	kMy_InvalidScrollBarKind	= 0,
	kMy_ScrollBarKindVertical	= 1,
	kMy_ScrollBarKindHorizontal = 2
};

/*!
Specifies the type of sheet (if any) that is currently
displayed.  This is used by the preferences context
monitor, so that it knows what settings were changed.
*/
enum My_SheetType
{
	kMy_SheetTypeNone			= 0,
	kMy_SheetTypeFormat			= 1,
	kMy_SheetTypeScreenSize		= 2,
	kMy_SheetTypeTranslation	= 3
};

/*!
IMPORTANT

The following values MUST agree with the control IDs in the
"Tab" NIB from the package "TerminalWindow.nib".
*/
HIViewID const	idMyLabelTabTitle			= { 'TTit', 0/* ID */ };

} // anonymous namespace

#pragma mark Types
namespace {

typedef std::map< TerminalViewRef, TerminalScreenRef >			My_ScreenByTerminalView;
typedef std::map< HIWindowRef, TerminalWindowRef >				My_TerminalWindowByHIWindowRef;
typedef std::map< NSWindow*, TerminalWindowRef >				My_TerminalWindowByNSWindow;
typedef std::vector< TerminalScreenRef >						My_TerminalScreenList;
typedef std::vector< TerminalViewRef >							My_TerminalViewList;
typedef std::vector< Undoables_ActionRef >						My_UndoableActionList;
typedef std::multimap< TerminalScreenRef, TerminalViewRef >		My_ViewsByScreen;

typedef MemoryBlockReferenceTracker< TerminalWindowRef >	My_RefTracker;
typedef Registrar< TerminalWindowRef, My_RefTracker >		My_RefRegistrar;

struct My_TerminalWindow
{
	My_TerminalWindow  (Preferences_ContextRef, Preferences_ContextRef, Preferences_ContextRef, Boolean);
	~My_TerminalWindow ();
	
	My_RefRegistrar				refValidator;				// ensures this reference is recognized as a valid one
	TerminalWindowRef			selfRef;					// redundant reference to self, for convenience
	
	ListenerModel_Ref			changeListenerModel;		// who to notify for various kinds of changes to this terminal data
	
	NSWindow*					window;						// the Cocoa window reference for the terminal window (wrapping Carbon)
	CFRetainRelease				tab;						// the Mac OS window reference (if any) for the sister window acting as a tab
	CarbonEventHandlerWrap*		tabContextualMenuHandlerPtr;// used to track contextual menu clicks in tabs
	CarbonEventHandlerWrap*		tabDragHandlerPtr;			// used to track drags that enter tabs
	WindowGroupRef				tabAndWindowGroup;			// WindowGroupRef; forces the window and its tab to move together
	Float32						tabOffsetInPixels;			// used to position the tab drawer, if any
	Float32						tabSizeInPixels;			// used to position and size a tab drawer, if any
	HIToolbarRef				toolbar;					// customizable toolbar of icons at the top
	CFRetainRelease				toolbarItemBell;			// if present, enable/disable bell item
	CFRetainRelease				toolbarItemKillRestart;		// if present, kill/restart item
	CFRetainRelease				toolbarItemLED1;			// if present, LED #1 status item
	CFRetainRelease				toolbarItemLED2;			// if present, LED #2 status item
	CFRetainRelease				toolbarItemLED3;			// if present, LED #3 status item
	CFRetainRelease				toolbarItemLED4;			// if present, LED #4 status item
	CFRetainRelease				toolbarItemScrollLock;		// if present, scroll lock status item
	TerminalView_DisplayMode	preResizeViewDisplayMode;	// stored in case user invokes option key variation on resize
	CGDirectDisplayID			staggerDisplay;				// the display the window was on at the time "staggerIndex" was set;
															//     if the user attempts to stack windows and the window is now on
															//     a different display, "staggerIndex" is ignored and reset
	UInt16						staggerIndex;				// index in list of staggered windows for "staggerDisplay"
	
	struct
	{
		HIViewRef		scrollBarH;				// scroll bar used to specify which range of columns is visible
		HIViewRef		scrollBarV;				// scroll bar used to specify which range of rows is visible
	} controls;
	
	struct
	{
		Boolean						isOn;		// temporary flag to track full-screen mode (under Cocoa this will be easier to determine from the window)
		Boolean						isUsingOS;	// temporary flag; tracks windows that are currently Full Screen in system style so they can transition back in the same style
		UInt16						oldFontSize;		// font size prior to full-screen
		Rect						oldContentBounds;	// old window boundaries, content area
		TerminalView_DisplayMode	oldMode;			// previous terminal resize effect
		TerminalView_DisplayMode	newMode;			// full-screen terminal resize effect
	} fullScreen;
	
	Boolean						isObscured;				// is the window hidden, via a command in the Window menu?
	Boolean						isDead;					// is the window title flagged to indicate a disconnected session?
	Boolean						isLEDOn[4];				// true only if this terminal light is lit
	Boolean						viewSizeIndependent;	// true only temporarily, to handle transitional cases such as full-screen mode
	Preferences_ContextWrap		recentSheetContext;		// defined temporarily while a Preferences-dependent sheet (such as screen size) is up
	My_SheetType				sheetType;				// if a sheet is active, this is a hint as to what settings can be put in the context
	FindDialog_Ref				searchDialog;			// retains the user interface for finding text in the terminal buffer
	FindDialog_Options			recentSearchOptions;	// the options used during the last search in the dialog
	CFRetainRelease				recentSearchStrings;	// CFMutableArrayRef; the CFStrings used in searches since this window was opened
	CFRetainRelease				baseTitleString;		// user-provided title string; may be adorned prior to becoming the window title
	CFRetainRelease				preResizeTitleString;	// used to save the old title during resizes, where the title is overwritten
	ControlActionUPP			scrollProcUPP;							// handles scrolling activity
	CommonEventHandlers_WindowResizer	windowResizeHandler;			// responds to changes in the window size
	CommonEventHandlers_WindowResizer	tabDrawerWindowResizeHandler;	// responds to changes in the tab drawer size
	CarbonEventHandlerWrap		mouseWheelHandler;						// responds to scroll wheel events
	CarbonEventHandlerWrap		scrollTickHandler;						// responds to drawing events in the scroll bar
	EventHandlerUPP				commandUPP;								// wrapper for command callback
	EventHandlerRef				commandHandler;							// invoked whenever a terminal window command is executed
	EventHandlerUPP				windowClickActivationUPP;				// wrapper for window background clicks callback
	EventHandlerRef				windowClickActivationHandler;			// invoked whenever a terminal window is hit while inactive
	EventHandlerUPP				windowCursorChangeUPP;					// wrapper for window cursor change callback
	EventHandlerRef				windowCursorChangeHandler;				// invoked whenever the mouse cursor might change in a terminal window
	EventHandlerUPP				windowDragCompletedUPP;					// wrapper for window move completion callback
	EventHandlerRef				windowDragCompletedHandler;				// invoked whenever a terminal window has finished being moved by the user
	EventHandlerUPP				windowFullScreenUPP;					// wrapper for window full-screen callback
	EventHandlerRef				windowFullScreenHandler;				// invoked whenever a full-screen window event occurs for a terminal window
	EventHandlerUPP				windowResizeEmbellishUPP;				// wrapper for window resize callback
	EventHandlerRef				windowResizeEmbellishHandler;			// invoked whenever a terminal window is resized
	EventHandlerUPP				growBoxClickUPP;						// wrapper for grow box click callback
	EventHandlerRef				growBoxClickHandler;					// invoked whenever a terminal window’s grow box is clicked
	EventHandlerUPP				toolbarEventUPP;						// wrapper for toolbar callback
	EventHandlerRef				toolbarEventHandler;					// invoked whenever a toolbar needs an item created, etc.
	ListenerModel_ListenerWrap	sessionStateChangeEventListener;		// responds to changes in a session
	ListenerModel_ListenerWrap	terminalStateChangeEventListener;		// responds to changes in a terminal
	ListenerModel_ListenerWrap	terminalViewEventListener;				// responds to changes in a terminal view
	ListenerModel_ListenerWrap	toolbarStateChangeEventListener;		// responds to changes in a toolbar
	
	My_ViewsByScreen				screensToViews;			// map of a screen buffer to one or more views
	My_ScreenByTerminalView			viewsToScreens;			// map of views to screen buffers
	My_TerminalScreenList			allScreens;				// all screen buffers represented in the two maps above
	My_TerminalViewList				allViews;				// all views represented in the two maps above
	
	My_UndoableActionList			installedActions;		// undoable things installed on behalf of this window
};
typedef My_TerminalWindow*			My_TerminalWindowPtr;
typedef My_TerminalWindow const*	My_TerminalWindowConstPtr;

/*!
Context data for the context ID "kUndoableContextIdentifierTerminalFontSizeChanges".
*/
struct UndoDataFontSizeChanges
{
	Undoables_ActionRef		action;				//!< used to manage the Undo command
	TerminalWindowRef		terminalWindow;		//!< which window was reformatted
	Boolean					undoFontSize;		//!< is this Undo action going to reverse the font size changes?
	Boolean					undoFont;			//!< is this Undo action going to reverse the font changes?
	UInt16					fontSize;			//!< the old font size (ignored if "undoFontSize" is false)
	CFRetainRelease			fontName;			//!< the old font (ignored if "undoFont" is false)
};
typedef UndoDataFontSizeChanges*		UndoDataFontSizeChangesPtr;

/*!
Context data for the context ID "kUndoableContextIdentifierTerminalDimensionChanges".
*/
struct UndoDataScreenDimensionChanges
{
	Undoables_ActionRef		action;				//!< used to manage the Undo command
	TerminalWindowRef		terminalWindow;		//!< which window was resized
	UInt16					columns;			//!< the old screen width
	UInt16					rows;				//!< the old screen height
};
typedef UndoDataScreenDimensionChanges*		UndoDataScreenDimensionChangesPtr;

typedef MemoryBlockPtrLocker< TerminalWindowRef, My_TerminalWindow >	My_TerminalWindowPtrLocker;
typedef LockAcquireRelease< TerminalWindowRef, My_TerminalWindow >		My_TerminalWindowAutoLocker;

} // anonymous namespace

#pragma mark Internal Method Prototypes
namespace {

void					calculateIndexedWindowPosition	(My_TerminalWindowPtr, UInt16, UInt16, HIPoint*);
void					calculateWindowPosition			(My_TerminalWindowPtr, UInt16*, UInt16*, HIRect*);
void					changeNotifyForTerminalWindow	(My_TerminalWindowPtr, TerminalWindow_Change, void*);
IconRef					createBellOffIcon				();
IconRef					createBellOnIcon				();
IconRef					createCustomizeToolbarIcon		();
IconRef					createFullScreenIcon			();
IconRef					createHideWindowIcon			();
IconRef					createKillSessionIcon			();
IconRef					createScrollLockOffIcon			();
IconRef					createScrollLockOnIcon			();
IconRef					createLEDOffIcon				();
IconRef					createLEDOnIcon					();
IconRef					createPrintIcon					();
IconRef					createRestartSessionIcon		();
void					createViews						(My_TerminalWindowPtr);
Boolean					createTabWindow					(My_TerminalWindowPtr);
NSWindow*				createWindow					();
TerminalScreenRef		getActiveScreen					(My_TerminalWindowPtr);
TerminalViewRef			getActiveView					(My_TerminalWindowPtr);
My_ScrollBarKind		getScrollBarKind				(My_TerminalWindowPtr, HIViewRef);
TerminalViewRef			getScrollBarView				(My_TerminalWindowPtr, HIViewRef);
void					getViewSizeFromWindowSize		(My_TerminalWindowPtr, SInt16, SInt16, SInt16*, SInt16*);
void					getWindowSizeFromViewSize		(My_TerminalWindowPtr, SInt16, SInt16, SInt16*, SInt16*);
void					handleFindDialogClose			(FindDialog_Ref);
void					handleNewDrawerWindowSize		(WindowRef, Float32, Float32, void*);
void					handleNewSize					(WindowRef, Float32, Float32, void*);
void					installTickHandler				(My_TerminalWindowPtr);
void					installUndoFontSizeChanges		(TerminalWindowRef, Boolean, Boolean);
void					installUndoScreenDimensionChanges	(TerminalWindowRef);
bool					lessThanIfGreaterArea			(HIWindowRef, HIWindowRef);
OSStatus				receiveHICommand				(EventHandlerCallRef, EventRef, void*);
OSStatus				receiveMouseWheelEvent			(EventHandlerCallRef, EventRef, void*);
OSStatus				receiveScrollBarDraw			(EventHandlerCallRef, EventRef, void*);
OSStatus				receiveTabDragDrop				(EventHandlerCallRef, EventRef, void*);
OSStatus				receiveToolbarEvent				(EventHandlerCallRef, EventRef, void*);
OSStatus				receiveWindowCursorChange		(EventHandlerCallRef, EventRef, void*);
OSStatus				receiveWindowDragCompleted		(EventHandlerCallRef, EventRef, void*);
OSStatus				receiveWindowFullScreenChange	(EventHandlerCallRef, EventRef, void*);
OSStatus				receiveWindowResize				(EventHandlerCallRef, EventRef, void*);
HIWindowRef				returnCarbonWindow				(My_TerminalWindowPtr);
UInt16					returnGrowBoxHeight				(My_TerminalWindowPtr);
UInt16					returnGrowBoxWidth				(My_TerminalWindowPtr);
UInt16					returnScrollBarHeight			(My_TerminalWindowPtr);
UInt16					returnScrollBarWidth			(My_TerminalWindowPtr);
UInt16					returnStatusBarHeight			(My_TerminalWindowPtr);
UInt16					returnToolbarHeight				(My_TerminalWindowPtr);
CGDirectDisplayID		returnWindowDisplay				(HIWindowRef);
void					reverseFontChanges				(Undoables_ActionInstruction, Undoables_ActionRef, void*);
void					reverseScreenDimensionChanges	(Undoables_ActionInstruction, Undoables_ActionRef, void*);
void					scrollProc						(HIViewRef, HIViewPartCode);
void					sessionStateChanged				(ListenerModel_Ref, ListenerModel_Event, void*, void*);
void					setCarbonWindowFullScreenIcon	(HIWindowRef, Boolean);
void					setCocoaWindowFullScreenIcon	(NSWindow*, Boolean);
OSStatus				setCursorInWindow				(HIWindowRef, Point, UInt32);
void					setScreenPreferences			(My_TerminalWindowPtr, Preferences_ContextRef, Boolean = false);
void					setStandardState				(My_TerminalWindowPtr, UInt16, UInt16, Boolean, Boolean = false);
void					setTerminalWindowFullScreen		(My_TerminalWindowPtr, Boolean, Boolean);
void					setUpForFullScreenModal			(My_TerminalWindowPtr, Boolean, Boolean, My_FullScreenState);
void					setViewFormatPreferences		(My_TerminalWindowPtr, Preferences_ContextRef);
void					setViewSizeIndependentFromWindow(My_TerminalWindowPtr, Boolean);
void					setViewTranslationPreferences	(My_TerminalWindowPtr, Preferences_ContextRef);
void					setWarningOnWindowClose			(My_TerminalWindowPtr, Boolean);
void					setWindowAndTabTitle			(My_TerminalWindowPtr, CFStringRef);
void					setWindowToIdealSizeForDimensions	(My_TerminalWindowPtr, UInt16, UInt16, Boolean = false);
void					setWindowToIdealSizeForFont		(My_TerminalWindowPtr);
void					sheetClosed						(GenericDialog_Ref, Boolean);
Preferences_ContextRef	sheetContextBegin				(My_TerminalWindowPtr, Quills::Prefs::Class, My_SheetType);
void					sheetContextEnd					(My_TerminalWindowPtr);
void					terminalStateChanged			(ListenerModel_Ref, ListenerModel_Event, void*, void*);
void					terminalViewStateChanged		(ListenerModel_Ref, ListenerModel_Event, void*, void*);
void					updateScrollBars				(My_TerminalWindowPtr);

} // anonymous namespace

#pragma mark Variables
namespace {

My_TerminalWindowByHIWindowRef&	gTerminalWindowRefsByHIWindowRef ()	{ static My_TerminalWindowByHIWindowRef x; return x; }
My_TerminalWindowByNSWindow&	gCarbonTerminalWindowRefsByNSWindow ()		{ static My_TerminalWindowByNSWindow x; return x; }
My_TerminalWindowByNSWindow&	gTerminalWindowRefsByNSWindow ()		{ static My_TerminalWindowByNSWindow x; return x; }
My_RefTracker&					gTerminalWindowValidRefs ()		{ static My_RefTracker x; return x; }
My_TerminalWindowPtrLocker&		gTerminalWindowPtrLocks ()		{ static My_TerminalWindowPtrLocker x; return x; }
IconRef&					gBellOffIcon ()					{ static IconRef x = createBellOffIcon(); return x; }
IconRef&					gBellOnIcon ()					{ static IconRef x = createBellOnIcon(); return x; }
IconRef&					gCustomizeToolbarIcon ()		{ static IconRef x = createCustomizeToolbarIcon(); return x; }
IconRef&					gFullScreenIcon ()				{ static IconRef x = createFullScreenIcon(); return x; }
IconRef&					gHideWindowIcon ()				{ static IconRef x = createHideWindowIcon(); return x; }
IconRef&					gKillSessionIcon ()				{ static IconRef x = createKillSessionIcon(); return x; }
IconRef&					gLEDOffIcon ()					{ static IconRef x = createLEDOffIcon(); return x; }
IconRef&					gLEDOnIcon ()					{ static IconRef x = createLEDOnIcon(); return x; }
IconRef&					gPrintIcon ()					{ static IconRef x = createPrintIcon(); return x; }
IconRef&					gRestartSessionIcon ()			{ static IconRef x = createRestartSessionIcon(); return x; }
IconRef&					gScrollLockOffIcon ()			{ static IconRef x = createScrollLockOffIcon(); return x; }
IconRef&					gScrollLockOnIcon ()			{ static IconRef x = createScrollLockOnIcon(); return x; }
Float32						gDefaultTabWidth = 0.0;		// set later
Float32						gDefaultTabHeight = 0.0;	// set later

} // anonymous namespace


#pragma mark Public Methods

/*!
Creates a new terminal window that is configured in the given
ways.  If any problems occur, nullptr is returned; otherwise,
a reference to the new terminal window is returned.

Any of the contexts can be "nullptr" if you want to rely on
defaults.  These contexts only determine initial settings;
future changes to the contexts will not affect the window.

The "inNoStagger" argument should normally be set to false; it
is used for the special case of a new window that duplicates
an existing window (so that it can be animated into its final
position).

IMPORTANT:	In general, you should NOT create terminal windows
			this way; use the Session Factory module.

(3.0)
*/
TerminalWindowRef
TerminalWindow_New  (Preferences_ContextRef		inTerminalInfoOrNull,
					 Preferences_ContextRef		inFontInfoOrNull,
					 Preferences_ContextRef		inTranslationOrNull,
					 Boolean					inNoStagger)
{
	TerminalWindowRef	result = nullptr;
	
	
	try
	{
		result = REINTERPRET_CAST(new My_TerminalWindow(inTerminalInfoOrNull, inFontInfoOrNull, inTranslationOrNull,
														inNoStagger),
									TerminalWindowRef);
	}
	catch (std::bad_alloc)
	{
		result = nullptr;
	}
	return result;
}// New


/*!
Creates a new terminal window that is configured in the given
ways.  If any problems occur, nullptr is returned; otherwise,
a reference to the new terminal window is returned.

Any of the contexts can be "nullptr" if you want to rely on
defaults.  These contexts only determine initial settings;
future changes to the contexts will not affect the window.

The "inNoStagger" argument should normally be set to false; it
is used for the special case of a new window that duplicates
an existing window (so that it can be animated into its final
position).

IMPORTANT:	In general, you should NOT create terminal windows
			this way; use the Session Factory module.

(2016.03)
*/
TerminalWindowRef
TerminalWindow_NewCocoaViewTest		(Preferences_ContextRef		inTerminalInfoOrNull,
									 Preferences_ContextRef		inFontInfoOrNull,
									 Preferences_ContextRef		inTranslationOrNull,
									 Boolean					inNoStagger)
{
	TerminalWindowRef	result = nullptr;
	
	
	try
	{
		result = REINTERPRET_CAST(new My_TerminalWindow(inTerminalInfoOrNull, inFontInfoOrNull, inTranslationOrNull,
														inNoStagger),
									TerminalWindowRef);
	}
	catch (std::bad_alloc)
	{
		result = nullptr;
	}
	return result;
}// NewCocoaViewTest


/*!
This method cleans up a terminal window by destroying all
of the data associated with it.  On output, your copy of
the given reference will be set to nullptr.

(3.0)
*/
void
TerminalWindow_Dispose   (TerminalWindowRef*	inoutRefPtr)
{
	if (gTerminalWindowPtrLocks().isLocked(*inoutRefPtr))
	{
		Console_Warning(Console_WriteLine, "attempt to dispose of locked terminal window");
	}
	else if (false == TerminalWindow_IsValid(*inoutRefPtr))
	{
		Console_Warning(Console_WriteValueAddress, "attempt to dispose of invalid terminal window", *inoutRefPtr);
	}
	else
	{
		// clean up
		{
			My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), *inoutRefPtr);
			
			
			delete ptr;
		}
		*inoutRefPtr = nullptr;
	}
}// Dispose


/*!
Returns the base name of the specified terminal window,
without any special adornments added by the Terminal Window
module.  (To copy the complete title, just ask the OS.)

(4.0)
*/
void
TerminalWindow_CopyWindowTitle	(TerminalWindowRef	inRef,
								 CFStringRef&		outName)
{
	outName = nullptr;
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		if (ptr->baseTitleString.exists())
		{
			outName = CFStringCreateCopy(kCFAllocatorDefault, ptr->baseTitleString.returnCFStringRef());
		}
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to copy title of invalid terminal window", inRef);
	}
}// CopyWindowTitle


/*!
Displays the Find dialog for the given terminal window,
handling searches automatically.  On Mac OS X, the dialog
is a sheet, so this routine may return immediately without
the user having finished searching.

(3.0)
*/
void
TerminalWindow_DisplayTextSearchDialog	(TerminalWindowRef		inRef)
{
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		if (nullptr == ptr->searchDialog)
		{
			ptr->searchDialog = FindDialog_New(inRef, handleFindDialogClose,
												ptr->recentSearchStrings.returnCFMutableArrayRef(),
												ptr->recentSearchOptions);
		}
		
		// display a text search dialog (automatically closed when the user clicks a button)
		FindDialog_Display(ptr->searchDialog);
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to display text search dialog on invalid terminal window", inRef);
	}
}// DisplayTextSearchDialog


/*!
Determines if the specified mouse (or drag) event is hitting
any part of the given terminal window.

(3.1)
*/
Boolean
TerminalWindow_EventInside	(TerminalWindowRef	inRef,
							 EventRef			inMouseEvent)
{
	Boolean		result = false;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		HIViewRef						hitView = nullptr;
		OSStatus						error = noErr;
		
		
		error = HIViewGetViewForMouseEvent(HIViewGetRoot(returnCarbonWindow(ptr)), inMouseEvent, &hitView);
		if (noErr == error)
		{
			result = true;
		}
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to test event in invalid terminal window", inRef);
	}
	return result;
}// EventInside


/*!
Determines if a Mac OS window has a terminal window
reference.

(3.0)
*/
Boolean
TerminalWindow_ExistsFor	(WindowRef	inWindow)
{
	auto		toPair = gTerminalWindowRefsByHIWindowRef().find(inWindow);
	Boolean		result = (gTerminalWindowRefsByHIWindowRef().end() != toPair);
	
	
	return result;
}// ExistsFor


/*!
Makes a terminal window the target of keyboard input, but does
not force it to be in front.

See also TerminalWindow_IsFocused().

This is a TEMPORARY API that should be used in any code that
cannot use TerminalWindow_ReturnNSWindow() to manipulate the
Cocoa window directly.  All calls to the Carbon SelectWindow(),
that had been using TerminalWindow_ReturnWindow(), should
DEFINITELY change to call this routine, instead (which
manipulates the Cocoa window internally).

(4.0)
*/
void
TerminalWindow_Focus	(TerminalWindowRef	inRef)
{
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		[ptr->window makeKeyWindow];
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to focus invalid terminal window", inRef);
	}
}// Focus


/*!
Returns the font and/or size used by the terminal
screens in the specified window.  If you are not
interested in one of the values, simply pass nullptr
as its input.

IMPORTANT:	This API is under evaluation.  It does
			not allow for the possibility of more
			than one terminal view per window, in
			the sense that each view theoretically
			can have its own font and size.

(3.0)
*/
void
TerminalWindow_GetFontAndSize	(TerminalWindowRef	inRef,
								 CFStringRef*		outFontFamilyNameOrNull,
								 UInt16*			outFontSizeOrNull)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	
	
	TerminalView_GetFontAndSize(getActiveView(ptr)/* TEMPORARY */, outFontFamilyNameOrNull, outFontSizeOrNull);
}// GetFontAndSize


/*!
Returns references to all virtual terminal screen buffers
that can be seen in the given terminal window.  In order
for the result to be greater than 1, there must be at
least two distinct source buffers (and not just two
distinct split-pane views) used by the window.

Use TerminalWindow_ReturnScreenCount() to determine an
appropriate size for your array, then allocate an array
and pass the count as "inArrayLength".  Note that this
is the number of elements, not necessarily the number
of bytes!

Currently, MacTerm only has one screen per window, so
only one screen will be returned.  However, if your code
*could* vary depending on the number of screens in a
window, you should use this API to iterate properly now,
to ensure correct behavior in the future.

(3.0)
*/
void
TerminalWindow_GetScreens	(TerminalWindowRef		inRef,
							 UInt16					inArrayLength,
							 TerminalScreenRef*		outScreenArray,
							 UInt16*				outActualCountOrNull)
{
	if (nullptr != outScreenArray)
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		auto							maxIterator = ptr->allScreens.begin();
		
		
		// based on the available space given by the caller,
		// find where the list “past-the-end” is
		std::advance(maxIterator, INTEGER_MINIMUM(inArrayLength, ptr->allScreens.size()));
		
		// copy all possible screen buffer references
		for (auto screenIterator = ptr->allScreens.begin(); screenIterator != maxIterator; ++screenIterator)
		{
			*outScreenArray++ = *screenIterator;
		}
		if (nullptr != outActualCountOrNull)
		{
			*outActualCountOrNull = STATIC_CAST(ptr->allScreens.size(), UInt16);
		}
	}
}// GetScreens


/*!
Returns the number of columns and/or the number of
rows visible in the specified terminal window.  If
there are multiple split-panes (multiple screens),
the result is the sum of the views shown by all.

(3.0)
*/
void
TerminalWindow_GetScreenDimensions	(TerminalWindowRef	inRef,
									 UInt16*			outColumnCountPtrOrNull,
									 UInt16*			outRowCountPtrOrNull)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	
	
	if (outColumnCountPtrOrNull != nullptr) *outColumnCountPtrOrNull = Terminal_ReturnColumnCount(getActiveScreen(ptr)/* TEMPORARY */);
	if (outRowCountPtrOrNull != nullptr) *outRowCountPtrOrNull = Terminal_ReturnRowCount(getActiveScreen(ptr)/* TEMPORARY */);
}// GetScreenDimensions


/*!
Returns the tab width, in pixels, of the specified terminal
window (or height, for left/right tabs).  If the window has never
been explicitly sized, some default size will be returned.
Otherwise, the size most recently set with
TerminalWindow_SetTabWidth() will be returned.

See also TerminalWindow_GetTabWidthAvailable().

\retval kTerminalWindow_ResultOK
if there are no errors

\retval kTerminalWindow_ResultInvalidReference
if the specified terminal window is unrecognized

\retval kTerminalWindow_ResultGenericFailure
if no window has ever had a tab; "outWidthHeightInPixels" will be 0

(3.1)
*/
TerminalWindow_Result
TerminalWindow_GetTabWidth	(TerminalWindowRef	inRef,
							 Float32&			outWidthHeightInPixels)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	TerminalWindow_Result			result = kTerminalWindow_ResultOK;
	
	
	if (false == TerminalWindow_IsValid(inRef))
	{
		result = kTerminalWindow_ResultInvalidReference;
		Console_Warning(Console_WriteValueAddress, "attempt to TerminalWindow_GetTabWidth() with invalid reference", inRef);
		outWidthHeightInPixels = 0;
	}
	else
	{
		Float32 const	kMinimumWidth = 32.0; // arbitrary
		
		
		if (ptr->tabSizeInPixels < kMinimumWidth)
		{
			result = kTerminalWindow_ResultGenericFailure;
			outWidthHeightInPixels = kMinimumWidth;
		}
		else
		{
			outWidthHeightInPixels = ptr->tabSizeInPixels;
		}
	}
	return result;
}// GetTabWidth


/*!
Returns the space for tabs, in pixels, along the tab edge of the
specified terminal window, at the current window size.  This is
automatically a vertical measurement if the user preference is
for left-edge or right-edge tabs.

Note that it is not generally a good idea to rely on the width
available to one window.  Every window in a workspace should be
consulted, and the smallest range available to any of the windows
should be used as the available range for all of them.  This way,
a tab cannot be positioned in such a way that the parent window
is forced to be widened.

See also TerminalWindow_GetTabWidth().

\retval kTerminalWindow_ResultOK
if there are no errors

\retval kTerminalWindow_ResultInvalidReference
if the specified terminal window is unrecognized

\retval kTerminalWindow_ResultGenericFailure
if no window has ever had a tab; "outWidthHeightInPixels" will be 0

(3.1)
*/
TerminalWindow_Result
TerminalWindow_GetTabWidthAvailable		(TerminalWindowRef	inRef,
										 Float32&			outMaxWidthHeightInPixels)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	TerminalWindow_Result			result = kTerminalWindow_ResultOK;
	
	
	if (false == TerminalWindow_IsValid(inRef))
	{
		result = kTerminalWindow_ResultInvalidReference;
		Console_Warning(Console_WriteValueAddress, "attempt to TerminalWindow_GetTabWidthAvailable() with invalid reference", inRef);
		outMaxWidthHeightInPixels = 500.0; // arbitrary!
	}
	else
	{
		Rect					windowRect;
		OSStatus				error = noErr;
		OptionBits				preferredEdge = kWindowEdgeTop;
		Preferences_Result		prefsResult = Preferences_GetData(kPreferences_TagWindowTabPreferredEdge,
																	sizeof(preferredEdge), &preferredEdge);
		
		
		if (kPreferences_ResultOK != prefsResult)
		{
			preferredEdge = kWindowEdgeTop;
		}
		
		error = GetWindowBounds(returnCarbonWindow(ptr), kWindowStructureRgn, &windowRect);
		assert_noerr(error);
		
		if ((kWindowEdgeLeft == preferredEdge) || (kWindowEdgeRight == preferredEdge))
		{
			outMaxWidthHeightInPixels = windowRect.bottom - windowRect.top;
		}
		else
		{
			outMaxWidthHeightInPixels = windowRect.right - windowRect.left;
		}
	}
	return result;
}// GetTabWidthAvailable


/*!
Returns references to all terminal views in the given
terminal window.  In order for any views to be
returned, there must be at least two terminal screen
controls in use by the window.

Use TerminalWindow_GetViewCount() to determine an
appropriate size for your array, then allocate an array
and pass the count as "inArrayLength".  Note that this
is the number of elements, not necessarily the number
of bytes!

Currently, MacTerm only has one view per window, so
only one view will be returned.  However, if your code
*could* vary depending on the number of views in a
window, you should use this API to iterate properly now,
to ensure correct behavior in the future.

IMPORTANT:	The TerminalWindow_GetViewsInGroup() API is
			more specific and recommended.  This API
			should now be avoided.

(3.0)
*/
void
TerminalWindow_GetViews		(TerminalWindowRef	inRef,
							 UInt16				inArrayLength,
							 TerminalViewRef*	outViewArray,
							 UInt16*			outActualCountOrNull)
{
	if (nullptr != outViewArray)
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		auto							maxIterator = ptr->allViews.begin();
		
		
		// based on the available space given by the caller,
		// find where the list “past-the-end” is
		std::advance(maxIterator, INTEGER_MINIMUM(inArrayLength, ptr->allViews.size()));
		
		// copy all possible view references
		for (auto viewIterator = ptr->allViews.begin(); viewIterator != maxIterator; ++viewIterator)
		{
			*outViewArray++ = *viewIterator;
		}
		if (nullptr != outActualCountOrNull)
		{
			*outActualCountOrNull = STATIC_CAST(ptr->allViews.size(), UInt16);
		}
	}
}// GetViews


/*!
Returns references to all terminal views in the given
terminal window that belong to the specified group.

By specifying a group filter, you can automatically
retrieve an ordered list of views pertinent to your
purpose.

Use TerminalWindow_GetViewCountInGroup() to determine
an appropriate size for your array, then allocate an
array and pass the count as "inArrayLength" (and be
sure to pass the same group constant, too!).  Note
that this is the number of *elements*, not necessarily
the number of bytes!

Currently, MacTerm only has one view per window, so
only one view will be returned.  However, if your code
*could* vary depending on the number of views in a
window, you should use this API to iterate properly now,
to ensure correct behavior in the future.

(3.0)
*/
TerminalWindow_Result
TerminalWindow_GetViewsInGroup	(TerminalWindowRef			inRef,
								 TerminalWindow_ViewGroup	inViewGroup,
								 UInt16						inArrayLength,
								 TerminalViewRef*			outViewArray,
								 UInt16*					outActualCountOrNull)
{
	TerminalWindow_Result	result = kTerminalWindow_ResultGenericFailure;
	
	
	switch (inViewGroup)
	{
	case kTerminalWindow_ViewGroupEverything:
	case kTerminalWindow_ViewGroupActive:
		if (nullptr != outViewArray)
		{
			My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
			auto							maxIterator = ptr->allViews.begin();
			
			
			// based on the available space given by the caller,
			// find where the list “past-the-end” is
			std::advance(maxIterator, INTEGER_MINIMUM(inArrayLength, ptr->allViews.size()));
			
			// copy all possible view references
			for (auto viewIterator = ptr->allViews.begin(); viewIterator != maxIterator; ++viewIterator)
			{
				*outViewArray++ = *viewIterator;
			}
			if (nullptr != outActualCountOrNull)
			{
				*outActualCountOrNull = STATIC_CAST(ptr->allViews.size(), UInt16);
			}
			result = kTerminalWindow_ResultOK;
		}
		break;
	
	default:
		// ???
		break;
	}
	return result;
}// GetViewsInGroup


/*!
Returns "true" only if the specified window currently has the
keyboard focus.

See also TerminalWindow_Focus().

This is a TEMPORARY API that should be used in any code that
cannot use TerminalWindow_ReturnNSWindow() to manipulate the
Cocoa window directly.  Calls to the Carbon IsWindowFocused(),
that had been using TerminalWindow_ReturnWindow(), should
DEFINITELY change to call this routine, instead (which
manipulates the Cocoa window internally).

(4.0)
*/
Boolean
TerminalWindow_IsFocused	(TerminalWindowRef	inRef)
{
	Boolean		result = false;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = (YES == [ptr->window isKeyWindow]);
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to check “is focused” property of invalid terminal window", inRef);
	}
	return result;
}// IsFocused


/*!
Returns "true" only if the specified terminal window is currently
taking over its entire display in a special mode.  If true, this
does not guarantee that there are no other windows in a full-screen
mode.

(4.1)
*/
Boolean
TerminalWindow_IsFullScreen		(TerminalWindowRef	inRef)
{
	Boolean		result = false;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = ptr->fullScreen.isOn;
	}
	return result;
}// IsFullScreen


/*!
Returns "true" if any terminal window is full-screen.  If the
user has enabled the OS full-screen mechanism, some windows
could be full-screen without preventing access to the rest of
the application; thus, “mode” in this context does not
necessarily mean the application can do nothing else.

See also TerminalWindow_IsFullScreen(), which checks to see if
a particular window is full-screen.

(4.1)
*/
Boolean
TerminalWindow_IsFullScreenMode ()
{
	__block Boolean		result = false;
	
	
	// NOTE: although this could be implemented with a simple
	// counter, that is vulnerable to unexpected problems (e.g.
	// a window somehow closing where the close notification
	// is missed and the counter is out of date); this is a
	// small-N linear search that can be changed later if
	// necessary
	SessionFactory_ForEachTerminalWindow
	(^(TerminalWindowRef	inTerminalWindow,
	   Boolean&				outStop)
	{
		if (TerminalWindow_IsFullScreen(inTerminalWindow))
		{
			result = true;
			outStop = YES;
		}
	});
	
	return result;
}// IsFullScreenMode


/*!
Returns "true" only if the specified window is obscured,
meaning it is invisible to the user but technically
considered a visible window.  This is the state used by
the “Hide Front Window” command.

(3.0)
*/
Boolean
TerminalWindow_IsObscured	(TerminalWindowRef	inRef)
{
	Boolean		result = false;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = ptr->isObscured;
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to check “obscured” property of invalid terminal window", inRef);
	}
	return result;
}// IsObscured


/*!
Returns "true" only if the specified window has a tab
appearance, as set with TerminalWindow_SetTabAppearance().

(4.0)
*/
Boolean
TerminalWindow_IsTab	(TerminalWindowRef	inRef)
{
	Boolean		result = false;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = ptr->tab.exists();
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to check “is tab” property of invalid terminal window", inRef);
	}
	return result;
}// IsTab


/*!
Returns "true" only if the specified terminal window has
not been destroyed with TerminalWindow_Dispose(), and is
not in the process of being destroyed.

Most of the time, checking for a null reference is enough,
and efficient; this check may be slower, but is important
if you are handling something indirectly or asynchronously
(where a terminal window could have been destroyed at any
time).

(4.1)
*/
Boolean
TerminalWindow_IsValid	(TerminalWindowRef	inRef)
{
	Boolean		result = ((nullptr != inRef) && (gTerminalWindowValidRefs().find(inRef) != gTerminalWindowValidRefs().end()));
	
	
	return result;
}// IsValid


/*!
Changes the settings of every view in the specified group,
to include the recognized settings of the given context.  You
might use this, for example, to do a batch-mode change of all
the fonts and colors of a terminal window’s views.

A preferences class can be provided as a hint to indicate what
should be changed.  For example, Quills::Prefs::FORMAT will set
fonts and colors on views, but Quills::Prefs::TERMINAL will set
internal screen buffer preferences.

Currently, the only supported group is the active view,
"kTerminalWindow_ViewGroupActive".

Returns true only if successful.

WARNING:	The Quills::Prefs::TRANSLATION class can be set up
			with this API, but only as a helper for Session APIs!
			If you actually want to change encodings, be sure to
			use Session_ReturnTranslationConfiguration() and
			copy changes there, so that the Session can see them.
			A Session-level change will, in turn, call this
			routine to update the views.

(4.0)
*/
Boolean
TerminalWindow_ReconfigureViewsInGroup	(TerminalWindowRef			inRef,
										 TerminalWindow_ViewGroup	inViewGroup,
										 Preferences_ContextRef		inContext,
										 Quills::Prefs::Class		inPrefsClass)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	Boolean							result = false;
	
	
	if (kTerminalWindow_ViewGroupActive == inViewGroup)
	{
		switch (inPrefsClass)
		{
		case Quills::Prefs::FORMAT:
			setViewFormatPreferences(ptr, inContext);
			result = true;
			break;
		
		case Quills::Prefs::TERMINAL:
			setScreenPreferences(ptr, inContext);
			result = true;
			break;
		
		case Quills::Prefs::TRANSLATION:
			setViewTranslationPreferences(ptr, inContext);
			result = true;
			break;
		
		default:
			// ???
			break;
		}
	}
	return result;
}// ReconfigureViewsInGroup


/*!
Returns the Terminal Window associated with the most recently
active non-floating Cocoa or Carbon window, or nullptr if there
is none.

Use this in cases where you want to interact with the terminal
window even if something else is focused, e.g. if a floating
window is currently the target of keyboard input.

(4.0)
*/
TerminalWindowRef
TerminalWindow_ReturnFromMainWindow ()
{
	NSWindow*			activeWindow = [NSApp mainWindow];
	TerminalWindowRef	result = [activeWindow terminalWindowRef];
	
	
	if (nullptr == result)
	{
		// old method; temporary, for Carbon
		result = TerminalWindow_ReturnFromWindow(ActiveNonFloatingWindow());
	}
	return result;
}// ReturnFromMainWindow


/*!
Returns the Terminal Window associated with the Cocoa or Carbon
window that has keyboard focus, or nullptr if there is none.  In
particular, if a floating window is focused, this will always
return nullptr.

Use this in cases where the target of keyboard input absolutely
must be a terminal, and cannot be a floating non-terminal window.

(4.0)
*/
TerminalWindowRef
TerminalWindow_ReturnFromKeyWindow ()
{
	NSWindow*			activeWindow = [NSApp keyWindow];
	TerminalWindowRef	result = [activeWindow terminalWindowRef];
	
	
	if (nullptr == result)
	{
		// old method; temporary, for Carbon
		result = TerminalWindow_ReturnFromWindow(GetUserFocusWindow());
	}
	return result;
}// ReturnFromKeyWindow


/*!
Returns the Terminal Window associated with the specified
window, if any.  A window that is not a terminal window
will cause a nullptr return value.

See also TerminalWindow_ReturnFromActiveWindow().

(3.0)
*/
TerminalWindowRef
TerminalWindow_ReturnFromWindow		(WindowRef	inWindow)
{
	TerminalWindowRef	result = nullptr;
	auto				toPair = gTerminalWindowRefsByHIWindowRef().find(inWindow);
	
	
	if (gTerminalWindowRefsByHIWindowRef().end() != toPair)
	{
		result = toPair->second;
	}
	
	return result;
}// ReturnFromWindow


/*!
Returns the Cocoa window for the specified terminal window.

IMPORTANT:	If an API exists to manipulate a terminal window,
			use the Terminal Window API; only use the Cocoa
			window when absolutely necessary.

(4.0)
*/
NSWindow*
TerminalWindow_ReturnNSWindow	(TerminalWindowRef	inRef)
{
	NSWindow*	result = nil;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = ptr->window;
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to find Cocoa window of invalid terminal window", inRef);
	}
	return result;
}// ReturnNSWindow


/*!
Returns the number of distinct virtual terminal screen
buffers in the given terminal window.  For example,
even if the window contains 3 split-pane views of the
same screen buffer, the result will still be 1.

Currently, MacTerm only has one screen per window,
so the return value will always be 1.  However, if your
code *could* vary depending on the number of screens in
a window, you should use this API along with
TerminalWindow_GetScreens() to iterate properly now, to
ensure correct behavior in the future.

(3.0)
*/
UInt16
TerminalWindow_ReturnScreenCount	(TerminalWindowRef		inRef)
{
	UInt16		result = 0;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = STATIC_CAST(ptr->allScreens.size(), UInt16);
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to count screens of invalid terminal window", inRef);
	}
	return result;
}// ReturnScreenCount


/*!
Returns a reference to the virtual terminal that has most
recently had keyboard focus in the given terminal window.
Thus, a valid reference is returned even if no terminal
screen control has the keyboard focus.

WARNING:	MacTerm is going to change in the future to
			support multiple screens per window.  Be sure
			to use TerminalWindow_GetScreens() instead of
			this routine if it is appropriate to iterate
			over all screens in a window.

(3.0)
*/
TerminalScreenRef
TerminalWindow_ReturnScreenWithFocus	(TerminalWindowRef	inRef)
{
	TerminalScreenRef	result = nullptr;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = getActiveScreen(ptr);
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to find focused screen of invalid terminal window", inRef);
	}
	return result;
}// ReturnScreenWithFocus


/*!
Returns the Mac OS window reference for the tab drawer that
is sometimes attached to a terminal window.

IMPORTANT:	This is not for general use.  It is an accessor
			temporarily required to enable alpha-channel
			changes, and will probably go way.

(4.0)
*/
HIWindowRef
TerminalWindow_ReturnTabWindow		(TerminalWindowRef	inRef)
{
	HIWindowRef		result = nullptr;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		if (ptr->tab.exists())
		{
			result = REINTERPRET_CAST(ptr->tab.returnHIObjectRef(), HIWindowRef);
		}
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to find tab window of invalid terminal window", inRef);
	}
	return result;
}// ReturnTabWindow


/*!
Returns the number of distinct terminal views in the
given terminal window.  For example, if a window has a
single split, the result will be 2.

Currently, MacTerm only has one view per window, so
the return value will always be 1.  However, if your
code *could* vary depending on the number of views in
a window, you should use this API along with
TerminalWindow_GetViewsInGroup() to iterate properly
now, to ensure correct behavior in the future.

By definition, this function is equivalent to calling
TerminalWindow_ReturnViewCountInGroup() with a group
of "kTerminalWindow_ViewGroupEverything".

(3.0)
*/
UInt16
TerminalWindow_ReturnViewCount		(TerminalWindowRef		inRef)
{
	UInt16		result = 0;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = STATIC_CAST(ptr->allViews.size(), UInt16);
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to count views of invalid terminal window", inRef);
	}
	return result;
}// ReturnViewCount


/*!
Returns the number of distinct terminal views in the
given group of the given terminal window.  Use this
to determine the length of the array you need to pass
into TerminalWindow_GetViewsInGroup().

(3.0)
*/
UInt16
TerminalWindow_ReturnViewCountInGroup	(TerminalWindowRef			inRef,
										 TerminalWindow_ViewGroup	inGroup)
{
	UInt16		result = 0;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		switch (inGroup)
		{
		case kTerminalWindow_ViewGroupEverything:
			result = STATIC_CAST(ptr->allViews.size(), UInt16);
			assert(result == TerminalWindow_ReturnViewCount(inRef));
			break;
		
		case kTerminalWindow_ViewGroupActive:
			// currently, only one tab per window so the result is the same
			result = STATIC_CAST(ptr->allViews.size(), UInt16);
			assert(result == TerminalWindow_ReturnViewCount(inRef));
			break;
		
		default:
			// ???
			break;
		}
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to count views in group of invalid terminal window", inRef);
	}
	return result;
}// ReturnViewCountInGroup


/*!
Returns a reference to the screen view that has most
recently had keyboard focus in the given terminal window.
Thus, a valid reference is returned even if no terminal
screen control has the keyboard focus.

WARNING:	MacTerm is going to change in the future to
			support multiple views per window.  Be sure
			to use TerminalWindow_GetViews() instead of
			this routine if it is appropriate to iterate
			over all views in a window.

(3.0)
*/
TerminalViewRef
TerminalWindow_ReturnViewWithFocus		(TerminalWindowRef	inRef)
{
	TerminalViewRef		result = nullptr;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = getActiveView(ptr);
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to find focused view of invalid terminal window", inRef);
	}
	return result;
}// ReturnViewWithFocus


/*!
Returns the Mac OS window reference for the specified
terminal window.

DEPRECATED.  You should generally manipulate the Cocoa window,
if anything (which can also be used to find the Carbon window).
See TerminalWindow_ReturnNSWindow().

IMPORTANT:	If an API exists to manipulate a terminal
			window, use the Terminal Window API; only
			use the Mac OS window reference when
			absolutely necessary.

(3.0)
*/
HIWindowRef
TerminalWindow_ReturnWindow		(TerminalWindowRef	inRef)
{
	HIWindowRef		result = nullptr;
	
	
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		result = returnCarbonWindow(ptr);
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to find Carbon window of invalid terminal window", inRef);
	}
	return result;
}// ReturnWindow


/*!
Puts a terminal window in front of other windows.  For
convenience, if "inFocus" is true, TerminalWindow_Focus() is
also called (which is commonly required at the same time).

See also TerminalWindow_Focus() and TerminalWindow_IsFocused().

This is a TEMPORARY API that should be used in any code that
cannot use TerminalWindow_ReturnNSWindow() to manipulate the
Cocoa window directly.  All calls to the Carbon SelectWindow(),
that had been using TerminalWindow_ReturnWindow(), should
DEFINITELY change to call this routine, instead (which
manipulates the Cocoa window internally).

(4.0)
*/
void
TerminalWindow_Select	(TerminalWindowRef	inRef,
						 Boolean			inFocus)
{
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		[ptr->window orderFront:nil];
		if (inFocus)
		{
			TerminalWindow_Focus(inRef);
		}
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to select invalid terminal window", inRef);
	}
}// Select


/*!
Changes the font and/or size used by all screens in
the specified terminal window.  If the font name is
nullptr, the font is not changed.  If the size is 0,
the size is not changed.

The font and size are currently tied to the window
dimensions, so adjusting these parameters will force
the window to resize to use the new space.  In the
future, it may make more sense to leave the user’s
chosen size intact (at least, when the new view size
will fit within the current window).

IMPORTANT:	This API is under evaluation.  It does
			not allow for the possibility of more
			than one terminal view per window, in
			the sense that each view theoretically
			can have its own font and size.

See also setViewFormatPreferences().

(3.0)
*/
void
TerminalWindow_SetFontAndSize	(TerminalWindowRef		inRef,
								 CFStringRef			inFontFamilyNameOrNull,
								 Float32				inFontSizeOrZero)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	TerminalViewRef					activeView = getActiveView(ptr);
	TerminalView_DisplayMode		oldMode = kTerminalView_DisplayModeNormal;
	TerminalView_Result				viewResult = kTerminalView_ResultOK;
	
	
	// update terminal screen font attributes; temporarily change the
	// view mode to allow this, since the view might automatically
	// be controlling its font size
	oldMode = TerminalView_ReturnDisplayMode(activeView);
	viewResult = TerminalView_SetDisplayMode(activeView, kTerminalView_DisplayModeNormal);
	assert(kTerminalView_ResultOK == viewResult);
	viewResult = TerminalView_SetFontAndSize(activeView, inFontFamilyNameOrNull, inFontSizeOrZero);
	assert(kTerminalView_ResultOK == viewResult);
	viewResult = TerminalView_SetDisplayMode(activeView, oldMode);
	assert(kTerminalView_ResultOK == viewResult);
	
	// IMPORTANT: this window adjustment should match setViewFormatPreferences()
	unless (ptr->viewSizeIndependent)
	{
		setWindowToIdealSizeForFont(ptr);
	}
}// SetFontAndSize


/*!
Temporary, controlled by the Session in response to changes
in user preferences.  Updates all Carbon and Cocoa windows
appropriately to let the user enter or exit Full Screen with
the standard mechanism.  This should not be called except as
a side effect of preferences changes.

(4.1)
*/
void
TerminalWindow_SetFullScreenIconsEnabled	(Boolean	inAllTerminalWindowsHaveFullScreenIcons)
{
	My_TerminalWindowByNSWindow::const_iterator		toPair;
	My_TerminalWindowByNSWindow::const_iterator		endPairs(gCarbonTerminalWindowRefsByNSWindow().end());
	
	
	for (toPair = gCarbonTerminalWindowRefsByNSWindow().begin(); toPair != endPairs; ++toPair)
	{
		setCarbonWindowFullScreenIcon(REINTERPRET_CAST([toPair->first windowRef], HIWindowRef), inAllTerminalWindowsHaveFullScreenIcons);
	}
	
	endPairs = gTerminalWindowRefsByNSWindow().end();
	for (toPair = gTerminalWindowRefsByNSWindow().begin(); toPair != endPairs; ++toPair)
	{
		setCocoaWindowFullScreenIcon(toPair->first, inAllTerminalWindowsHaveFullScreenIcons);
	}
}// SetFullScreenIconsEnabled


/*!
Renames a terminal window’s minimized Dock tile, notifying
listeners that the window title has changed.

(3.0)
*/
void
TerminalWindow_SetIconTitle		(TerminalWindowRef	inRef,
								 CFStringRef		inName)
{
@autoreleasepool {
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	
	
	[ptr->window setMiniwindowTitle:(NSString*)inName];
	changeNotifyForTerminalWindow(ptr, kTerminalWindow_ChangeIconTitle, ptr->selfRef/* context */);
}// @autoreleasepool
}// SetIconTitle


/*!
Set to "true" if you want to hide the specified window
(as in the “Hide Front Window” command).  An obscured
window is invisible to the user but technically
considered a visible window.

If "inIsHidden" is false, the window is automatically
restored in every way (e.g. unminimized from the Dock).

IMPORTANT:	Currently, this function ought to be the
			preferred way to show a terminal window,
			otherwise there are corner cases where a
			window could become visible and usable but
			still be “marked” as hidden.  This should
			be reimplemented to use window event
			handlers so that the obscured state is
			corrected whenever a window is redisplayed
			(in any way).

(3.0)
*/
void
TerminalWindow_SetObscured	(TerminalWindowRef	inRef,
							 Boolean			inIsHidden)
{
@autoreleasepool {
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	
	
	if (ptr->isObscured != inIsHidden)
	{
		ptr->isObscured = inIsHidden;
		if (inIsHidden)
		{
			// hide the window and notify listeners of the event (that ought to trigger
			// actions such as a zoom rectangle effect, updating Window menu items, etc.)
			[ptr->window orderOut:nil];
			
			// notify interested listeners about the change in state
			changeNotifyForTerminalWindow(ptr, kTerminalWindow_ChangeObscuredState, ptr->selfRef/* context */);
		}
		else
		{
			// show the window and notify listeners of the event (that ought to trigger
			// actions such as updating Window menu items, etc.)
			[ptr->window makeKeyAndOrderFront:nil];
			
			// also restore the window if it was collapsed/minimized
			if ([ptr->window isMiniaturized]) [ptr->window deminiaturize:nil];
			
			// notify interested listeners about the change in state
			changeNotifyForTerminalWindow(ptr, kTerminalWindow_ChangeObscuredState, ptr->selfRef/* context */);
		}
	}
}// @autoreleasepool
}// SetObscured


/*!
Changes the dimensions of the visible screen area in the
given terminal window.  The window is resized accordingly.

See also setScreenPreferences().

(3.0)
*/
void
TerminalWindow_SetScreenDimensions	(TerminalWindowRef	inRef,
									 UInt16				inNewColumnCount,
									 UInt16				inNewRowCount,
									 Boolean			UNUSED_ARGUMENT(inSendToRecordingScripts))
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	TerminalScreenRef				activeScreen = getActiveScreen(ptr);
	
	
	Terminal_SetVisibleScreenDimensions(activeScreen, inNewColumnCount, inNewRowCount);
	
	// IMPORTANT: this window adjustment should match setScreenPreferences()
	unless (ptr->viewSizeIndependent)
	{
		setWindowToIdealSizeForDimensions(ptr, inNewColumnCount, inNewRowCount);
	}
}// SetScreenDimensions


/*!
Creates a sister window that appears to be attached to the
specified terminal window, acting as its tab.  This is a
visual adornment only; you typically use this for more than
one terminal window and then place them into a window group
that ensures only one is visible at a time.

IMPORTANT:	You should only call this routine on visible
			terminal windows, otherwise the tab may not be
			displayed properly.  The result will only be
			"noErr" if the tab is properly displayed.

Note that since this affects only a single window, this is
not the proper API for general tab manipulation; it is a
low-level routine.  See the Workspace module.

(3.1)
*/
OSStatus
TerminalWindow_SetTabAppearance		(TerminalWindowRef		inRef,
									 Boolean				inIsTab)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	OSStatus						result = noErr;
	
	
	if (inIsTab)
	{
		HIWindowRef		tabWindow = nullptr;
		Boolean			isNew = false;
		
		
		// create a sister tab window and group it with the terminal window
		if (false == ptr->tab.exists())
		{
			Boolean		createOK = createTabWindow(ptr);
			
			
			assert(createOK);
			assert(ptr->tab.exists());
			isNew = true;
		}
		
		tabWindow = REINTERPRET_CAST(ptr->tab.returnHIObjectRef(), HIWindowRef);
		
		if (isNew)
		{
			// update the tab display to match the window title
			TerminalWindow_SetWindowTitle(inRef, ptr->baseTitleString.returnCFStringRef());
			
			// attach the tab to the top edge of the window
			result = SetDrawerParent(tabWindow, TerminalWindow_ReturnWindow(inRef));
			if (noErr == result)
			{
				OptionBits				preferredEdge = kWindowEdgeTop;
				Preferences_Result		prefsResult = Preferences_GetData(kPreferences_TagWindowTabPreferredEdge,
																			sizeof(preferredEdge), &preferredEdge);
				
				
				if (kPreferences_ResultOK != prefsResult)
				{
					preferredEdge = kWindowEdgeTop;
				}
				result = SetDrawerPreferredEdge(tabWindow, preferredEdge);
			}
		}
		else
		{
			// note that the drawer is NOT opened when it is first created,
			// above, because this would have the undesirable visual side effect
			// of an oversized tab sliding out in the wrong position; instead,
			// this function is called again, later; at that point, the tab is
			// no longer new, and is opened here at the correct size
			if (kWindowDrawerOpen != GetDrawerState(tabWindow))
			{
				// IMPORTANT: This will return paramErr if the window is invisible.
				result = OpenDrawer(tabWindow, kWindowEdgeDefault, false/* asynchronously */);
			}
		}
	}
	else
	{
		// remove window from group and destroy tab
		HIWindowRef		tabWindow = REINTERPRET_CAST(ptr->tab.returnHIObjectRef(), HIWindowRef);
		
		
		if (ptr->tab.exists())
		{
			// IMPORTANT: This will return paramErr if the window is invisible.
			result = CloseDrawer(tabWindow, false/* asynchronously */);
		}
	}
	return result;
}// SetTabAppearance


/*!
Specifies the position of the tab (if any) for this window, and
optionally its width; set the width to FLT_MAX to auto-size.

This is a visual adornment only; you typically use this when
windows are grouped and you want all tabs to be visible at
the same time.

WARNING:	Prior to Snow Leopard, the Mac OS X window manager
			will not allow a drawer to be cut off, and it solves
			this problem by resizing the *parent* (terminal)
			window to make room for the tab.  If you do not want
			this behavior, you need to check in advance how
			large the window is, and what a reasonable tab
			placement would be.

Note that since this affects only a single window, this is not
the proper API for general tab manipulation; it is a low-level
routine.  See the Workspace module.

\retval kTerminalWindow_ResultOK
if there are no errors

\retval kTerminalWindow_ResultInvalidReference
if the specified terminal window is unrecognized

\retval kTerminalWindow_ResultGenericFailure
if the specified terminal window has no tab (however,
the proper offset is still remembered)

(3.1)
*/
TerminalWindow_Result
TerminalWindow_SetTabPosition	(TerminalWindowRef	inRef,
								 Float32			inOffsetFromStartingPointInPixels,
								 Float32			inWidthInPixelsOrFltMax)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	TerminalWindow_Result			result = kTerminalWindow_ResultOK;
	
	
	if (false == TerminalWindow_IsValid(inRef))
	{
		result = kTerminalWindow_ResultInvalidReference;
		Console_Warning(Console_WriteValueAddress, "attempt to TerminalWindow_SetTabPosition() with invalid reference", inRef);
	}
	else
	{
		Float32 const	kWidth = (FLT_MAX == inWidthInPixelsOrFltMax) ? ptr->tabSizeInPixels : inWidthInPixelsOrFltMax;
		
		
		ptr->tabOffsetInPixels = inOffsetFromStartingPointInPixels;
		
		// “setting the width” has the side effect of putting the tab in the right place
		result = TerminalWindow_SetTabWidth(inRef, kWidth);
	}
	return result;
}// SetTabPosition


/*!
Specifies the size of the tab (if any) for this window,
including any frame it has.  This is a visual adornment
only; see also TerminalWindow_SetTabPosition().

Currently, for tabs attached to the left or right edges of
a window, the specified width may be ignored (not even
used as a height); these tabs tend to have uniform size.

You can pass "kTerminalWindow_DefaultMetaTabWidth" to
indicate that the tab should be resized to its ordinary
(default) width or height.

Note that since this affects only a single window, this is
not the proper API for general tab manipulation; it is a
low-level routine.  See the Workspace module.

\retval kTerminalWindow_ResultOK
if there are no errors

\retval kTerminalWindow_ResultInvalidReference
if the specified terminal window is unrecognized

\retval kTerminalWindow_ResultGenericFailure
if the specified terminal window has no tab (however,
the proper width is still remembered)

(3.1)
*/
TerminalWindow_Result
TerminalWindow_SetTabWidth	(TerminalWindowRef	inRef,
							 Float32			inWidthInPixels)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	TerminalWindow_Result			result = kTerminalWindow_ResultOK;
	
	
	if (false == TerminalWindow_IsValid(inRef))
	{
		result = kTerminalWindow_ResultInvalidReference;
		Console_Warning(Console_WriteValueAddress, "attempt to TerminalWindow_SetTabWidth() with invalid reference", inRef);
	}
	else
	{
		if (false == ptr->tab.exists())
		{
			result = kTerminalWindow_ResultGenericFailure;
		}
		else
		{
			// drawers are managed in terms of start and end offsets as opposed to
			// a “width”, so some roundabout calculations are done to find offsets
			HIWindowRef				tabWindow = REINTERPRET_CAST(ptr->tab.returnHIObjectRef(), HIWindowRef);
			HIWindowRef				parentWindow = GetDrawerParent(tabWindow);
			Rect					currentParentBounds;
			OSStatus				error = noErr;
			float					leadingOffset = kWindowOffsetUnchanged;
			OptionBits				preferredEdge = kWindowEdgeTop;
			Preferences_Result		prefsResult = Preferences_GetData(kPreferences_TagWindowTabPreferredEdge,
																		sizeof(preferredEdge), &preferredEdge);
			
			
			if (kPreferences_ResultOK != prefsResult)
			{
				preferredEdge = kWindowEdgeTop;
			}
			
			// the tab width must refer to the structure region of the tab window,
			// however the total space available to tabs is limited to the width
			// of the parent window’s content region, not its structure region
			error = GetWindowBounds(parentWindow, kWindowContentRgn, &currentParentBounds);
			assert_noerr(error);
			leadingOffset = STATIC_CAST(ptr->tabOffsetInPixels, float);
			if ((kWindowEdgeLeft == preferredEdge) || (kWindowEdgeRight == preferredEdge))
			{
				// currently, vertically-stacked tabs are all the same size
				ptr->tabSizeInPixels = gDefaultTabHeight;
			}
			else
			{
				ptr->tabSizeInPixels = inWidthInPixels;
			}
			
			// ensure that the drawer stays at its assigned size; but note that the
			// given tab width refers to the entire structure, whereas the constrained
			// dimensions are only for the interior (content region)
			{
				Float32		width = 0.0;
				Float32		height = 0.0;
				Rect		borderWidths;
				
				
				error = GetWindowStructureWidths(tabWindow, &borderWidths);
				assert_noerr(error);
				error = ptr->tabDrawerWindowResizeHandler.getWindowMaximumSize(width, height);
				assert_noerr(error);
				if ((kWindowEdgeTop == preferredEdge) || (kWindowEdgeBottom == preferredEdge))
				{
					ptr->tabDrawerWindowResizeHandler.setWindowMinimumSize
														(ptr->tabSizeInPixels - borderWidths.right - borderWidths.left, height);
					ptr->tabDrawerWindowResizeHandler.setWindowMaximumSize
														(ptr->tabSizeInPixels - borderWidths.right - borderWidths.left, height);
				}
				else
				{
					ptr->tabDrawerWindowResizeHandler.setWindowMinimumSize
														(width, ptr->tabSizeInPixels - borderWidths.bottom - borderWidths.top);
					ptr->tabDrawerWindowResizeHandler.setWindowMaximumSize
														(width, ptr->tabSizeInPixels - borderWidths.bottom - borderWidths.top);
				}
			}
			
			// resize the drawer; setting the trailing offset would be
			// counterproductive, because it would force the parent window
			// to remain relatively wide (or high, for left/right tabs)
			error = SetDrawerOffsets(tabWindow, leadingOffset, kWindowOffsetUnchanged);
			if (noErr != error)
			{
				Console_Warning(Console_WriteValue, "failed to set drawer offsets for terminal window, error", error);
			}
			
			// force a “resize” to cause the tab position to update immediately
			// (TEMPORARY: is there a better way to do this?)
			if ((kWindowEdgeTop == preferredEdge) || (kWindowEdgeBottom == preferredEdge))
			{
				++currentParentBounds.right;
				SetWindowBounds(parentWindow, kWindowContentRgn, &currentParentBounds);
				--currentParentBounds.right;
				SetWindowBounds(parentWindow, kWindowContentRgn, &currentParentBounds);
			}
			else
			{
				++currentParentBounds.bottom;
				SetWindowBounds(parentWindow, kWindowContentRgn, &currentParentBounds);
				--currentParentBounds.bottom;
				SetWindowBounds(parentWindow, kWindowContentRgn, &currentParentBounds);
			}
		}
	}
	return result;
}// SetTabWidth


/*!
Set to "true" to show a terminal window, and "false" to hide it.

This is a TEMPORARY API that should be used in any code that
cannot use TerminalWindow_ReturnNSWindow() to manipulate the
Cocoa window directly.  All calls to the Carbon ShowWindow() or
HideWindow(), that had been using TerminalWindow_ReturnWindow(),
should DEFINITELY change to call this routine, instead (which
manipulates the Cocoa window internally).

(4.0)
*/
void
TerminalWindow_SetVisible	(TerminalWindowRef	inRef,
							 Boolean			inIsVisible)
{
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		if (inIsVisible)
		{
			[ptr->window orderFront:nil];
		}
		else
		{
			[ptr->window orderOut:nil];
		}
	}
	else
	{
		Console_Warning(Console_WriteValueAddress, "attempt to display invalid terminal window", inRef);
	}
}// SetVisible


/*!
Renames a terminal window, notifying listeners that the
window title has changed.

The value of "inName" can be nullptr if you want the current
base title to be unchanged, but you want adornments to be
evaluated again (an updated session status, for instance).

See also TerminalWindow_CopyWindowTitle().

(3.0)
*/
void
TerminalWindow_SetWindowTitle	(TerminalWindowRef	inRef,
								 CFStringRef		inName)
{
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
	
	
	if (nullptr != inName)
	{
		ptr->baseTitleString.setWithRetain(inName);
	}
	
	if (nil != ptr->window)
	{
		if (ptr->isDead)
		{
			// add a visual indicator to the window title of disconnected windows
			CFRetainRelease		adornedCFString(CFStringCreateWithFormat
												(kCFAllocatorDefault, nullptr/* format options */,
													CFSTR("~ %@ ~")/* LOCALIZE THIS? */,
													ptr->baseTitleString.returnCFStringRef()),
												CFRetainRelease::kAlreadyRetained);
			
			
			if (adornedCFString.exists())
			{
				setWindowAndTabTitle(ptr, adornedCFString.returnCFStringRef());
			}
		}
		else if (nullptr != inName)
		{
			setWindowAndTabTitle(ptr, ptr->baseTitleString.returnCFStringRef());
		}
	}
	changeNotifyForTerminalWindow(ptr, kTerminalWindow_ChangeWindowTitle, ptr->selfRef/* context */);
}// SetWindowTitle


/*!
Rearranges all terminal windows so that their top-left
corners form an invisible, diagonal line.  The effect
is also animated, showing each window sliding into its
new position.

If there are several Spaces defined, this routine only
operates on windows in the current Space.  If windows
span multiple displays however, they will be arranged
separately on each display.

(3.0)
*/
void
TerminalWindow_StackWindows ()
{
	typedef std::vector< HIWindowRef >						My_WindowList;
	typedef std::map< CGDirectDisplayID, My_WindowList >	My_WindowsByDisplay; // which windows are on which devices?
	
	NSArray*				currentSpaceWindowNumbers = [NSWindow windowNumbersWithOptions:0];
	NSWindow*				activeWindow = [NSApp mainWindow];
	My_WindowsByDisplay		windowsByDisplay;
	
	
	// first determine which windows are on each display
	for (NSNumber* currentWindowNumber in currentSpaceWindowNumbers)
	{
		NSInteger			windowNumber = [currentWindowNumber integerValue];
		NSWindow*			window = [NSApp windowWithWindowNumber:windowNumber];
		TerminalWindowRef	terminalWindow = [window terminalWindowRef];
		
		
		if (nil != terminalWindow)
		{
			HIWindowRef const			kWindow = TerminalWindow_ReturnWindow(terminalWindow);
			CGDirectDisplayID const		kDisplayID = returnWindowDisplay(kWindow);
			My_WindowList&				windowsOnThisDisplay = windowsByDisplay[kDisplayID];
			
			
			if (windowsOnThisDisplay.empty())
			{
				// the first time a display’s window list is seen, allocate
				// an approximately-correct vector size up front (this value
				// will only be exactly right on single-display systems)
				windowsOnThisDisplay.reserve([currentSpaceWindowNumbers count]);
			}
			windowsOnThisDisplay.push_back(kWindow);
		}
		else
		{
			// not a terminal; ignore
		}
	}
	
	// sort windows by largest area arbitrarily to minimize the chance
	// that a window will be completely hidden by the stacking of other
	// windows on its display
	for (auto& displayWindowPair : windowsByDisplay)
	{
		My_WindowList&	windowsOnThisDisplay = displayWindowPair.second;
		
		
		std::sort(windowsOnThisDisplay.begin(), windowsOnThisDisplay.end(), lessThanIfGreaterArea);
	}
	
	// for each display, stack windows separately
	for (auto displayWindowPair : windowsByDisplay)
	{
		My_WindowList const&	windowsOnThisDisplay = displayWindowPair.second;
		auto					toWindow = windowsOnThisDisplay.begin();
		auto					endWindows = windowsOnThisDisplay.end();
		UInt16					staggerListIndexHint = 0;
		UInt16					localWindowIndexHint = 0;
		UInt16					transitioningWindowCount = 0;
		
		
		for (; toWindow != endWindows; ++toWindow, ++localWindowIndexHint)
		{
			// arbitrary limit: only animate a few windows (asynchronously)
			// per display, moving the rest into position immediately
			HIWindowRef const				kHIWindow = *toWindow;
			TerminalWindowRef const			kTerminalWindow = TerminalWindow_ReturnFromWindow(kHIWindow);
			NSWindow* const					kNSWindow = TerminalWindow_ReturnNSWindow(kTerminalWindow);
			Boolean const					kTooManyWindows = (transitioningWindowCount > 3/* arbitrary */);
			My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), kTerminalWindow);
			HIRect							originalStructureBounds;
			HIRect							structureBounds;
			HIRect							screenBounds;
			OSStatus						error = noErr;
			
			
			++transitioningWindowCount;
			
			error = HIWindowGetBounds(kHIWindow, kWindowStructureRgn, kHICoordSpaceScreenPixel, &structureBounds);
			assert_noerr(error);
			error = HIWindowGetGreatestAreaDisplay(kHIWindow, kWindowStructureRgn, kHICoordSpaceScreenPixel,
													nullptr/* display ID */, &screenBounds);
			assert_noerr(error);
			originalStructureBounds = structureBounds;
			
			// NOTE: on return, "structureBounds" is updated again
			calculateWindowPosition(ptr, &staggerListIndexHint, &localWindowIndexHint, &structureBounds);
			
			// if a window’s current position places it entirely on-screen
			// and its “stacked” location would put it partially off-screen,
			// do not relocate the window (presumably it was better before!)
			if ((false == CGRectContainsRect(screenBounds, originalStructureBounds)) ||
				CGRectContainsRect(screenBounds, structureBounds))
			{
				// select each window as it is stacked so that keyboard cycling
				// will be in sync with the new order of windows
				[kNSWindow orderFront:nil];
				
				if (kTooManyWindows)
				{
					// move the window immediately without animation
					error = HIWindowSetBounds(kHIWindow, kWindowStructureRgn, kHICoordSpaceScreenPixel,
												&structureBounds);
					assert_noerr(error);
				}
				else
				{
					// do a cool slide animation to move the window into place
					TransitionWindowOptions		transitionOptions;
					
					
					// transition asynchronously for minimum interruption to the user
					bzero(&transitionOptions, sizeof(transitionOptions));
					transitionOptions.version = 0;
					if (noErr !=
						TransitionWindowWithOptions(kHIWindow, kWindowSlideTransitionEffect, kWindowMoveTransitionAction,
													&structureBounds, true/* asynchronous */, &transitionOptions))
					{
						// on error, just move the window
						error = HIWindowSetBounds(kHIWindow, kWindowStructureRgn, kHICoordSpaceScreenPixel,
													&structureBounds);
						assert_noerr(error);
					}
				}
			}
		}
	}
	
	// restore original Z-order of active window
	[activeWindow makeKeyAndOrderFront:nil];
}// StackWindows


/*!
Arranges for a callback to be invoked whenever a setting
changes for a terminal window (such as its screen size).

IMPORTANT:	The context passed to the listener callback
			is reserved for passing information relevant
			to a change.  See "TerminalWindow.h" for
			comments on what the context means for each
			type of change.

(3.0)
*/
void
TerminalWindow_StartMonitoring	(TerminalWindowRef			inRef,
								 TerminalWindow_Change		inForWhatChange,
								 ListenerModel_ListenerRef	inListener)
{
	if (TerminalWindow_IsValid(inRef))
	{
		OSStatus						error = noErr;
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		// add a listener to the specified target’s listener model for the given setting change
		error = ListenerModel_AddListenerForEvent(ptr->changeListenerModel, inForWhatChange, inListener);
		if (noErr != error)
		{
			Console_Warning(Console_WriteValueFourChars, "failed to start monitoring terminal window change", inForWhatChange);
			Console_Warning(Console_WriteValue, "monitor installation error", error);
		}
	}
	else
	{
		Console_Warning(Console_WriteValueFourChars, "attempt to start monitoring invalid terminal window, event", inForWhatChange);
	}
}// StartMonitoring


/*!
Arranges for a callback to no longer be invoked whenever
a setting changes for a terminal window (such as its
screen size).

IMPORTANT:	The context passed to the listener callback
			is reserved for passing information relevant
			to a change.  See "TerminalWindow.h" for
			comments on what the context means for each
			type of change.

(3.0)
*/
void
TerminalWindow_StopMonitoring	(TerminalWindowRef			inRef,
								 TerminalWindow_Change		inForWhatChange,
								 ListenerModel_ListenerRef	inListener)
{
	if (TerminalWindow_IsValid(inRef))
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inRef);
		
		
		// add a listener to the specified target’s listener model for the given setting change
		ListenerModel_RemoveListenerForEvent(ptr->changeListenerModel, inForWhatChange, inListener);
	}
	else
	{
		Console_Warning(Console_WriteValueFourChars, "attempt to stop monitoring invalid terminal window, event", inForWhatChange);
	}
}// StopMonitoring


#pragma mark Internal Methods
namespace {

/*!
Constructor.  See TerminalWindow_New().

(3.0)
*/
My_TerminalWindow::
My_TerminalWindow	(Preferences_ContextRef		inTerminalInfoOrNull,
					 Preferences_ContextRef		inFontInfoOrNull,
					 Preferences_ContextRef		inTranslationInfoOrNull,
					 Boolean					inNoStagger)
:
// IMPORTANT: THESE ARE EXECUTED IN THE ORDER MEMBERS APPEAR IN THE CLASS.
refValidator(REINTERPRET_CAST(this, TerminalWindowRef), gTerminalWindowValidRefs()),
selfRef(REINTERPRET_CAST(this, TerminalWindowRef)),
changeListenerModel(ListenerModel_New(kListenerModel_StyleStandard,
										kConstantsRegistry_ListenerModelDescriptorTerminalWindowChanges)),
window(createWindow()),
tab(),
tabContextualMenuHandlerPtr(nullptr),
tabDragHandlerPtr(nullptr),
tabAndWindowGroup(nullptr),
tabOffsetInPixels(0.0),
tabSizeInPixels(0.0),
toolbar(nullptr),
toolbarItemBell(),
toolbarItemKillRestart(),
toolbarItemLED1(),
toolbarItemLED2(),
toolbarItemLED3(),
toolbarItemLED4(),
toolbarItemScrollLock(),
preResizeViewDisplayMode(kTerminalView_DisplayModeNormal/* corrected below */),
// controls initialized below
// toolbar initialized below
isObscured(false),
isDead(false),
viewSizeIndependent(false),
recentSheetContext(),
sheetType(kMy_SheetTypeNone),
searchDialog(nullptr),
recentSearchOptions(kFindDialog_OptionsDefault),
recentSearchStrings(CFArrayCreateMutable(kCFAllocatorDefault, 0/* limit; 0 = no size limit */, &kCFTypeArrayCallBacks),
					CFRetainRelease::kAlreadyRetained),
baseTitleString(),
scrollProcUPP(nullptr), // reset below
windowResizeHandler(),
tabDrawerWindowResizeHandler(),
mouseWheelHandler(GetApplicationEventTarget(), receiveMouseWheelEvent,
					CarbonEventSetInClass(CarbonEventClass(kEventClassMouse), kEventMouseWheelMoved),
					this->selfRef/* user data */),
scrollTickHandler(), // see createViews()
commandUPP(nullptr),
commandHandler(nullptr),
windowClickActivationUPP(nullptr),
windowClickActivationHandler(nullptr),
windowCursorChangeUPP(nullptr),
windowCursorChangeHandler(nullptr),
windowDragCompletedUPP(nullptr),
windowDragCompletedHandler(nullptr),
windowFullScreenUPP(nullptr),
windowFullScreenHandler(nullptr),
windowResizeEmbellishUPP(nullptr),
windowResizeEmbellishHandler(nullptr),
growBoxClickUPP(nullptr),
growBoxClickHandler(nullptr),
toolbarEventUPP(nullptr),
toolbarEventHandler(nullptr),
sessionStateChangeEventListener(),
terminalStateChangeEventListener(),
terminalViewEventListener(),
toolbarStateChangeEventListener(),
screensToViews(),
viewsToScreens(),
allScreens(),
allViews(),
installedActions()
{
@autoreleasepool {
	TerminalScreenRef		newScreen = nullptr;
	TerminalViewRef			newView = nullptr;
	Preferences_Result		preferencesResult = kPreferences_ResultOK;
	
	
	// for completeness, zero-out this structure (though it is set up
	// each time full-screen mode changes)
	bzero(&this->fullScreen, sizeof(this->fullScreen));
	
	// get defaults if no contexts provided; if these cannot be found
	// for some reason, that’s fine because defaults are set in case
	// of errors later on
	if (nullptr == inTerminalInfoOrNull)
	{
		preferencesResult = Preferences_GetDefaultContext(&inTerminalInfoOrNull, Quills::Prefs::TERMINAL);
		assert(kPreferences_ResultOK == preferencesResult);
		assert(nullptr != inTerminalInfoOrNull);
	}
	if (nullptr == inTranslationInfoOrNull)
	{
		preferencesResult = Preferences_GetDefaultContext(&inTranslationInfoOrNull, Quills::Prefs::TRANSLATION);
		assert(kPreferences_ResultOK == preferencesResult);
		assert(nullptr != inTranslationInfoOrNull);
	}
	if (nullptr == inFontInfoOrNull)
	{
		Boolean		chooseRandom = false;
		
		
		UNUSED_RETURN(Preferences_Result)Preferences_GetData(kPreferences_TagRandomTerminalFormats, sizeof(chooseRandom), &chooseRandom);
		if (chooseRandom)
		{
			std::vector< Preferences_ContextRef >	contextList;
			
			
			if (Preferences_GetContextsInClass(Quills::Prefs::FORMAT, contextList))
			{
				std::vector< UInt16 >	numberList(contextList.size());
				RandomWrap				generator;
				UInt16					counter = 0;
				
				
				for (auto toNumber = numberList.begin(); toNumber != numberList.end(); ++toNumber, ++counter)
				{
					*toNumber = counter;
				}
				std::random_shuffle(numberList.begin(), numberList.end(), generator);
				inFontInfoOrNull = contextList[numberList[0]];
			}
			
			if (nullptr == inFontInfoOrNull) chooseRandom = false; // error...
		}
		
		if (false == chooseRandom)
		{
			preferencesResult = Preferences_GetDefaultContext(&inFontInfoOrNull, Quills::Prefs::FORMAT);
			assert(kPreferences_ResultOK == preferencesResult);
			assert(nullptr != inFontInfoOrNull);
		}
	}
	
	// set up Window Info; it is important to do this right away
	// because this is relied upon by other code to find the
	// terminal window data attached to the Mac OS window
	assert(this->window != nil);
	gCarbonTerminalWindowRefsByNSWindow()[this->window] = this->selfRef;
	gTerminalWindowRefsByHIWindowRef()[returnCarbonWindow(this)] = this->selfRef;
	
	// set up the Help System
	HelpSystem_SetWindowKeyPhrase(returnCarbonWindow(this), kHelpSystem_KeyPhraseTerminals);
	
	// install a callback that responds as a window is resized
	this->windowResizeHandler.install(returnCarbonWindow(this), handleNewSize, this->selfRef/* user data */,
										250/* arbitrary minimum width */,
										200/* arbitrary minimum height */,
										SHRT_MAX/* maximum width */,
										SHRT_MAX/* maximum height */);
	assert(this->windowResizeHandler.isInstalled());
	
	// create controls
	{
		Terminal_Result		terminalError = kTerminal_ResultOK;
		
		
		terminalError = Terminal_NewScreen(inTerminalInfoOrNull, inTranslationInfoOrNull, &newScreen);
		if (terminalError == kTerminal_ResultOK)
		{
			newView = TerminalView_NewHIViewBased(newScreen, inFontInfoOrNull);
			if (newView != nullptr)
			{
				HIViewWrap		contentView(kHIViewWindowContentID, returnCarbonWindow(this));
				HIViewRef		terminalHIView = TerminalView_ReturnContainerHIView(newView);
				OSStatus		error = noErr;
				
				
				assert(contentView.exists());
				error = HIViewAddSubview(contentView, terminalHIView);
				assert_noerr(error);
				
				error = HIViewSetVisible(terminalHIView, true);
				assert_noerr(error);
				
				// remember the initial screen-to-view and view-to-screen mapping;
				// later, additional views or screens may be added
				this->screensToViews.insert(std::pair< TerminalScreenRef, TerminalViewRef >(newScreen, newView));
				this->viewsToScreens.insert(std::pair< TerminalViewRef, TerminalScreenRef >(newView, newScreen));
				this->allScreens.push_back(newScreen);
				this->allViews.push_back(newView);
				assert(this->screensToViews.find(newScreen) != this->screensToViews.end());
				assert(this->viewsToScreens.find(newView) != this->viewsToScreens.end());
				assert(!this->allScreens.empty());
				assert(this->allScreens.back() == newScreen);
				assert(!this->allViews.empty());
				assert(this->allViews.back() == newView);
			}
		}
	}
	createViews(this);
	
	// create toolbar icons
	if (noErr == HIToolbarCreate(kConstantsRegistry_HIToolbarIDTerminal,
									kHIToolbarAutoSavesConfig | kHIToolbarIsConfigurable, &this->toolbar))
	{
		// IMPORTANT: Do not invoke toolbar manipulation APIs at this stage,
		// until the event handlers below are installed.  A saved toolbar may
		// contain references to items that only the handlers below can create;
		// manipulation APIs often trigger creation of the entire toolbar, so
		// that means some saved items would fail to be inserted properly.
		
		// install a callback that can create any items needed for this
		// toolbar (used in the toolbar and in the customization sheet, etc.);
		// and, a callback that specifies which items are in the toolbar by
		// default, and which items are available in the customization sheet
		{
			EventTypeSpec const		whenToolbarEventOccurs[] =
									{
										{ kEventClassToolbar, kEventToolbarCreateItemWithIdentifier },
										{ kEventClassToolbar, kEventToolbarGetAllowedIdentifiers },
										{ kEventClassToolbar, kEventToolbarGetDefaultIdentifiers },
										{ kEventClassToolbar, kEventToolbarItemRemoved }
									};
			OSStatus				error = noErr;
			
			
			this->toolbarEventUPP = NewEventHandlerUPP(receiveToolbarEvent);
			error = InstallEventHandler(HIObjectGetEventTarget(this->toolbar), this->toolbarEventUPP,
										GetEventTypeCount(whenToolbarEventOccurs), whenToolbarEventOccurs,
										this->selfRef/* user data */,
										&this->toolbarEventHandler/* event handler reference */);
			assert_noerr(error);
		}
		
		// Check preferences for a stored toolbar; if one exists, leave the
		// toolbar display mode and size untouched, as the user will have
		// specified one; otherwise, initialize it to the desired look.
		//
		// IMPORTANT: This is a bit of a hack, as it relies on the key name
		// that Mac OS X happens to use for toolbar preferences as of 10.4.
		// If that ever changes, this code will be pointless.
		CFPropertyListRef	toolbarConfigPref = CFPreferencesCopyAppValue
												(CFSTR("HIToolbar Config com.mactelnet.toolbar.terminal"),
													kCFPreferencesCurrentApplication);
		Boolean				usingSavedToolbar = false;
		if (nullptr != toolbarConfigPref)
		{
			usingSavedToolbar = true;
			CFRelease(toolbarConfigPref), toolbarConfigPref = nullptr;
		}
		unless (usingSavedToolbar)
		{
			UNUSED_RETURN(OSStatus)HIToolbarSetDisplayMode(this->toolbar, kHIToolbarDisplayModeIconAndLabel);
			UNUSED_RETURN(OSStatus)HIToolbarSetDisplaySize(this->toolbar, kHIToolbarDisplaySizeSmall);
		}
		
		// the toolbar is NOT used yet and NOT released yet, until it is installed (below)
	}
	
	// set the standard state to be large enough for the specified number of columns and rows;
	// and, use the standard size, initially; then, perform a maximize/restore to correct the
	// initial-zoom quirk that would otherwise occur
	assert(nullptr != newScreen);
	if (nullptr != newScreen)
	{
		TerminalView_PixelWidth		screenWidth;
		TerminalView_PixelHeight	screenHeight;
		
		
		TerminalView_GetTheoreticalViewSize(getActiveView(this)/* TEMPORARY - must consider a list of views */,
											Terminal_ReturnColumnCount(newScreen), Terminal_ReturnRowCount(newScreen),
											screenWidth, screenHeight);
		setStandardState(this, screenWidth.integralPixels(), screenHeight.integralPixels(), true/* resize window */);
	}
	
	// stagger the window (this is effective for newly-created windows
	// that are alone; if a workspace is spawning them then the actual
	// window location will be overridden by the workspace configuration)
	unless (inNoStagger)
	{
		HIWindowRef		frontWindow = EventLoop_ReturnRealFrontWindow();
		HIRect			structureBounds;
		UInt16			staggerListIndex = 0;
		UInt16			localWindowIndex = 0;
		OSStatus		error = noErr;
		
		
		error = HIWindowGetBounds(returnCarbonWindow(this), kWindowStructureRgn, kHICoordSpaceScreenPixel,
									&structureBounds);
		assert_noerr(error);
		calculateWindowPosition(this, &staggerListIndex, &localWindowIndex, &structureBounds);
		
		// if the frontmost window already occupies the location for
		// the new window, offset it slightly
		if (nullptr != frontWindow)
		{
			HIRect		frontStructureBounds;
			
			
			if ((noErr == HIWindowGetBounds(frontWindow, kWindowStructureRgn, kHICoordSpaceScreenPixel,
											&frontStructureBounds)) &&
				CGPointEqualToPoint(frontStructureBounds.origin, structureBounds.origin))
			{
				structureBounds.origin.x += 20; // per Aqua Human Interface Guidelines
				structureBounds.origin.y += 20; // per Aqua Human Interface Guidelines
			}
		}
		
		error = HIWindowSetBounds(returnCarbonWindow(this), kWindowStructureRgn, kHICoordSpaceScreenPixel,
									&structureBounds);
		assert_noerr(error);
	}
	
	// set up callbacks to receive various state change notifications
	this->sessionStateChangeEventListener.setWithNoRetain(ListenerModel_NewStandardListener
															(sessionStateChanged, this->selfRef/* context */));
	SessionFactory_StartMonitoringSessions(kSession_ChangeSelected, this->sessionStateChangeEventListener.returnRef());
	SessionFactory_StartMonitoringSessions(kSession_ChangeState, this->sessionStateChangeEventListener.returnRef());
	SessionFactory_StartMonitoringSessions(kSession_ChangeStateAttributes, this->sessionStateChangeEventListener.returnRef());
	SessionFactory_StartMonitoringSessions(kSession_ChangeWindowInvalid, this->sessionStateChangeEventListener.returnRef());
	SessionFactory_StartMonitoringSessions(kSession_ChangeWindowTitle, this->sessionStateChangeEventListener.returnRef());
	this->terminalStateChangeEventListener.setWithNoRetain(ListenerModel_NewStandardListener
															(terminalStateChanged, this->selfRef/* context */));
	Terminal_StartMonitoring(newScreen, kTerminal_ChangeAudioState, this->terminalStateChangeEventListener.returnRef());
	Terminal_StartMonitoring(newScreen, kTerminal_ChangeExcessiveErrors, this->terminalStateChangeEventListener.returnRef());
	Terminal_StartMonitoring(newScreen, kTerminal_ChangeNewLEDState, this->terminalStateChangeEventListener.returnRef());
	Terminal_StartMonitoring(newScreen, kTerminal_ChangeScrollActivity, this->terminalStateChangeEventListener.returnRef());
	Terminal_StartMonitoring(newScreen, kTerminal_ChangeWindowFrameTitle, this->terminalStateChangeEventListener.returnRef());
	Terminal_StartMonitoring(newScreen, kTerminal_ChangeWindowIconTitle, this->terminalStateChangeEventListener.returnRef());
	Terminal_StartMonitoring(newScreen, kTerminal_ChangeWindowMinimization, this->terminalStateChangeEventListener.returnRef());
	this->terminalViewEventListener.setWithNoRetain(ListenerModel_NewStandardListener
													(terminalViewStateChanged, this->selfRef/* context */));
	TerminalView_StartMonitoring(newView, kTerminalView_EventScrolling, this->terminalViewEventListener.returnRef());
	TerminalView_StartMonitoring(newView, kTerminalView_EventSearchResultsExistence, this->terminalViewEventListener.returnRef());
	
	// install a callback that handles commands relevant to terminal windows
	{
		EventTypeSpec const		whenCommandExecuted[] =
								{
									{ kEventClassCommand, kEventCommandProcess }
								};
		OSStatus				error = noErr;
		
		
		this->commandUPP = NewEventHandlerUPP(receiveHICommand);
		error = InstallWindowEventHandler(returnCarbonWindow(this), this->commandUPP, GetEventTypeCount(whenCommandExecuted),
											whenCommandExecuted, this->selfRef/* user data */,
											&this->commandHandler/* event handler reference */);
		assert_noerr(error);
	}
	
	// install a callback that attempts to fix tab locations after a window is moved far enough below the menu bar
	{
		EventTypeSpec const		whenWindowDragCompleted[] =
								{
									{ kEventClassWindow, kEventWindowDragCompleted }
								};
		OSStatus				error = noErr;
		
		
		this->windowDragCompletedUPP = NewEventHandlerUPP(receiveWindowDragCompleted);
		error = InstallWindowEventHandler(returnCarbonWindow(this), this->windowDragCompletedUPP, GetEventTypeCount(whenWindowDragCompleted),
											whenWindowDragCompleted, this->selfRef/* user data */,
											&this->windowDragCompletedHandler/* event handler reference */);
		assert_noerr(error);
	}
	
	// install a callback that changes the mouse cursor appropriately
	{
		EventTypeSpec const		whenCursorChangeRequired[] =
								{
									{ kEventClassWindow, kEventWindowCursorChange },
									{ kEventClassKeyboard, kEventRawKeyModifiersChanged }
								};
		OSStatus				error = noErr;
		
		
		this->windowCursorChangeUPP = NewEventHandlerUPP(receiveWindowCursorChange);
		error = InstallWindowEventHandler(returnCarbonWindow(this), this->windowCursorChangeUPP, GetEventTypeCount(whenCursorChangeRequired),
											whenCursorChangeRequired, this->selfRef/* user data */,
											&this->windowCursorChangeHandler/* event handler reference */);
		assert_noerr(error);
	}
	
	// install a callback that responds to full-screen events for a terminal window
	{
		EventTypeSpec const		whenWindowFullScreenChanges[] =
								{
									{ kEventClassWindow, FUTURE_SYMBOL(241, kEventWindowFullScreenEnterStarted) },
									{ kEventClassWindow, FUTURE_SYMBOL(242, kEventWindowFullScreenEnterCompleted) },
									{ kEventClassWindow, FUTURE_SYMBOL(243, kEventWindowFullScreenExitStarted) },
									{ kEventClassWindow, FUTURE_SYMBOL(244, kEventWindowFullScreenExitCompleted) }
								};
		OSStatus				error = noErr;
		
		
		this->windowFullScreenUPP = NewEventHandlerUPP(receiveWindowFullScreenChange);
		error = InstallWindowEventHandler(returnCarbonWindow(this), this->windowFullScreenUPP, GetEventTypeCount(whenWindowFullScreenChanges),
											whenWindowFullScreenChanges, this->selfRef/* user data */,
											&this->windowFullScreenHandler/* event handler reference */);
		assert_noerr(error);
	}
	
	// install a callback that uses the title bar to display terminal dimensions during resize
	{
		EventTypeSpec const		whenWindowResizeStartsContinuesOrStops[] =
								{
									{ kEventClassWindow, kEventWindowResizeStarted },
									{ kEventClassWindow, kEventWindowBoundsChanging },
									{ kEventClassWindow, kEventWindowResizeCompleted }
								};
		OSStatus				error = noErr;
		
		
		this->windowResizeEmbellishUPP = NewEventHandlerUPP(receiveWindowResize);
		error = InstallWindowEventHandler(returnCarbonWindow(this), this->windowResizeEmbellishUPP, GetEventTypeCount(whenWindowResizeStartsContinuesOrStops),
											whenWindowResizeStartsContinuesOrStops, this->selfRef/* user data */,
											&this->windowResizeEmbellishHandler/* event handler reference */);
		assert_noerr(error);
	}
	
	// put the toolbar in the window
	{
		OSStatus	error = noErr;
		Boolean		headersCollapsed = false;
		
		
		error = SetWindowToolbar(returnCarbonWindow(this), this->toolbar);
		assert_noerr(error);
		
		// also show the toolbar, unless the user preference to collapse is set
		unless (kPreferences_ResultOK ==
				Preferences_GetData(kPreferences_TagHeadersCollapsed, sizeof(headersCollapsed),
									&headersCollapsed))
		{
			headersCollapsed = false; // assume headers aren’t collapsed, if preference can’t be found
		}
		unless (headersCollapsed)
		{
			error = ShowHideWindowToolbar(returnCarbonWindow(this), true/* show */, false/* animate */);
			assert_noerr(error);
		}
	}
	CFRelease(this->toolbar); // once set in the window, the toolbar is retained, so release the creation lock
	
	// enable drag tracking so that certain default toolbar behaviors work
	UNUSED_RETURN(OSStatus)SetAutomaticControlDragTrackingEnabledForWindow(returnCarbonWindow(this), true/* enabled */);
	
	// finish by applying any desired attributes to the screen
	{
		Boolean		flag = false;
		
		
		preferencesResult = Preferences_ContextGetData(inTerminalInfoOrNull, kPreferences_TagTerminalLineWrap,
														sizeof(flag), &flag);
		if (preferencesResult != kPreferences_ResultOK) flag = false;
		if (flag)
		{
			Terminal_EmulatorProcessCString(newScreen, "\033[?7h"); // turn on autowrap
		}
	}
	
	// override this default; technically terminal windows
	// are immediately closeable for the first 15 seconds
	setWarningOnWindowClose(this, false);
}// @autoreleasepool
}// My_TerminalWindow 2-argument constructor


/*!
Destructor.  See TerminalWindow_Dispose().

(3.0)
*/
My_TerminalWindow::
~My_TerminalWindow ()
{
@autoreleasepool {
	sheetContextEnd(this);
	
	if (nullptr != this->searchDialog)
	{
		FindDialog_Dispose(&this->searchDialog);
	}
	
	// now that the window is going away, destroy any Undo commands
	// that could be applied to this window
	for (auto actionRef : this->installedActions)
	{
		Undoables_RemoveAction(actionRef);
	}
	
	// show a hidden window just before it is destroyed (most importantly, notifying callbacks)
	TerminalWindow_SetObscured(this->selfRef, false);
	
	// remove any tab contextual menu handler
	if (nullptr != tabContextualMenuHandlerPtr) delete tabContextualMenuHandlerPtr, tabContextualMenuHandlerPtr = nullptr;
	
	// remove any tab drag handler
	if (nullptr != tabDragHandlerPtr) delete tabDragHandlerPtr, tabDragHandlerPtr = nullptr;
	
	// disable window command callback
	RemoveEventHandler(this->commandHandler), this->commandHandler = nullptr;
	DisposeEventHandlerUPP(this->commandUPP), this->commandUPP = nullptr;
	
	// disable window click activation callback
	RemoveEventHandler(this->windowClickActivationHandler), this->windowClickActivationHandler = nullptr;
	DisposeEventHandlerUPP(this->windowClickActivationUPP), this->windowClickActivationUPP = nullptr;
	
	// disable window cursor change callback
	RemoveEventHandler(this->windowCursorChangeHandler), this->windowCursorChangeHandler = nullptr;
	DisposeEventHandlerUPP(this->windowCursorChangeUPP), this->windowCursorChangeUPP = nullptr;
	
	// disable window move completion callback
	RemoveEventHandler(this->windowDragCompletedHandler), this->windowDragCompletedHandler = nullptr;
	DisposeEventHandlerUPP(this->windowDragCompletedUPP), this->windowDragCompletedUPP = nullptr;
	
	// disable window full-screen callback
	RemoveEventHandler(this->windowFullScreenHandler), this->windowFullScreenHandler = nullptr;
	DisposeEventHandlerUPP(this->windowFullScreenUPP), this->windowFullScreenUPP = nullptr;
	
	// disable window resize callback
	RemoveEventHandler(this->windowResizeEmbellishHandler), this->windowResizeEmbellishHandler = nullptr;
	DisposeEventHandlerUPP(this->windowResizeEmbellishUPP), this->windowResizeEmbellishUPP = nullptr;
	
	// disable size box click callback
	RemoveEventHandler(this->growBoxClickHandler), this->growBoxClickHandler = nullptr;
	DisposeEventHandlerUPP(this->growBoxClickUPP), this->growBoxClickUPP = nullptr;
	
	// disable toolbar callback
	RemoveEventHandler(this->toolbarEventHandler), this->toolbarEventHandler = nullptr;
	DisposeEventHandlerUPP(this->toolbarEventUPP), this->toolbarEventUPP = nullptr;
	
	// hide window
	if (nil != this->window)
	{
		Boolean		noAnimations = false;
		
		
		gTerminalWindowRefsByHIWindowRef().erase(returnCarbonWindow(this));
		gCarbonTerminalWindowRefsByNSWindow().erase(this->window);
		
		// determine if animation should occur
		unless (kPreferences_ResultOK ==
				Preferences_GetData(kPreferences_TagNoAnimations,
									sizeof(noAnimations), &noAnimations))
		{
			noAnimations = false; // assume a value, if preference can’t be found
		}
		
		// hide the window
		if (noAnimations)
		{
			[this->window orderOut:nil];
		}
		else
		{
			// this will hide the window immediately and replace it with a window
			// that looks exactly the same; that way, it is perfectly safe for
			// the rest of the destructor to run (cleaning up other state) even
			// if the animation finishes after the original window is destroyed
			CocoaAnimation_TransitionWindowForRemove(this->window);
		}
		
		// kill controls to disable callbacks
		KillControls(returnCarbonWindow(this));
	}
	
	// perform other clean-up
	DisposeControlActionUPP(this->scrollProcUPP), this->scrollProcUPP = nullptr;
	
	// unregister session callbacks
	SessionFactory_StopMonitoringSessions(kSession_ChangeSelected, this->sessionStateChangeEventListener.returnRef());
	SessionFactory_StopMonitoringSessions(kSession_ChangeState, this->sessionStateChangeEventListener.returnRef());
	SessionFactory_StopMonitoringSessions(kSession_ChangeStateAttributes, this->sessionStateChangeEventListener.returnRef());
	SessionFactory_StopMonitoringSessions(kSession_ChangeWindowInvalid, this->sessionStateChangeEventListener.returnRef());
	SessionFactory_StopMonitoringSessions(kSession_ChangeWindowTitle, this->sessionStateChangeEventListener.returnRef());
	
	// unregister screen buffer callbacks and destroy all buffers
	// (NOTE: perhaps this should be revisited, as a future feature
	// may be to allow multiple windows to use the same buffer; if
	// that were the case, killing one window should not necessarily
	// throw out its buffer)
	for (auto screenRef : this->allScreens)
	{
		Terminal_StopMonitoring(screenRef, kTerminal_ChangeAudioState, this->terminalStateChangeEventListener.returnRef());
		Terminal_StopMonitoring(screenRef, kTerminal_ChangeExcessiveErrors, this->terminalStateChangeEventListener.returnRef());
		Terminal_StopMonitoring(screenRef, kTerminal_ChangeNewLEDState, this->terminalStateChangeEventListener.returnRef());
		Terminal_StopMonitoring(screenRef, kTerminal_ChangeScrollActivity, this->terminalStateChangeEventListener.returnRef());
		Terminal_StopMonitoring(screenRef, kTerminal_ChangeWindowFrameTitle, this->terminalStateChangeEventListener.returnRef());
		Terminal_StopMonitoring(screenRef, kTerminal_ChangeWindowIconTitle, this->terminalStateChangeEventListener.returnRef());
		Terminal_StopMonitoring(screenRef, kTerminal_ChangeWindowMinimization, this->terminalStateChangeEventListener.returnRef());
	}
	
	// destroy all terminal views
	for (auto viewRef : this->allViews)
	{
		TerminalView_StopMonitoring(viewRef, kTerminalView_EventScrolling, this->terminalViewEventListener.returnRef());
		TerminalView_StopMonitoring(viewRef, kTerminalView_EventSearchResultsExistence, this->terminalViewEventListener.returnRef());
	}
	
	// throw away information about terminal window change listeners
	ListenerModel_Dispose(&this->changeListenerModel);
	
	// finally, dispose of the window
	if (nil != this->window)
	{
		HelpSystem_SetWindowKeyPhrase(returnCarbonWindow(this), kHelpSystem_KeyPhraseDefault); // clean up
		DisposeWindow(returnCarbonWindow(this));
		[this->window close], this->window = nil;
	}
	if (nullptr == this->tabAndWindowGroup)
	{
		ReleaseWindowGroup(this->tabAndWindowGroup), this->tabAndWindowGroup = nullptr;
	}
	
	// destroy all buffers (NOTE: perhaps this should be revisited, as
	// a future feature may be to allow multiple windows to use the same
	// buffer; if that were the case, killing one window should not
	// necessarily throw out its buffer)
	for (auto screenRef : this->allScreens)
	{
		Terminal_ReleaseScreen(&screenRef);
	}
}// @autoreleasepool
}// My_TerminalWindow destructor


/*!
Provides the global coordinates that the top-left corner
of the specified window’s frame (structure) would occupy
if it were in the requested stagger position.

The “stagger list index” is initially zero.  The very
first window (at “local window index 0”) in list index 0
will sit precisely at the user’s requested window
stacking origin, if it’s on the window’s display.  As
windows are stacked, adjust the “local window index” so
that the next window is placed diagonally down and to
the right of the previous one.  Once a window touches
the bottom of the screen, increment “stagger list index”
by one so that the next window will once again sit near
the user’s preferred stacking origin.  Each stagger list
is offset slightly to the right of the preceding one so
that windows can never completely overlap.

(4.1)
*/
void
calculateIndexedWindowPosition	(My_TerminalWindowPtr	inPtr,
								 UInt16					inStaggerListIndex,
								 UInt16					inLocalWindowIndex,
								 HIPoint*				outPositionPtr)
{
	if ((nullptr != inPtr) && (nullptr != outPositionPtr))
	{
		// calculate the stagger offset
		CGPoint		stackingOrigin;
		CGPoint		stagger;
		CGRect		screenRect;
		
		
		// determine the user’s preferred stacking origin
		// (TEMPORARY; ideally this preference can be per-display)
		unless (kPreferences_ResultOK ==
				Preferences_GetData(kPreferences_TagWindowStackingOrigin, sizeof(stackingOrigin),
									&stackingOrigin))
		{
			stackingOrigin = CGPointMake(40, 40); // assume a default, if preference can’t be found
		}
		
		if (inStaggerListIndex > 0)
		{
			// when previous stagger stacks hit the bottom of the
			// screen, arbitrarily shift new stacks over slightly
			stackingOrigin.x += (inStaggerListIndex * 60); // arbitrary
		}
		
		// the stagger amount on Mac OS X is set by the Aqua Human Interface Guidelines
		stagger = CGPointMake(20, 20);
		
		// convert to floating-point rectangle
		{
			Rect	integerRect;
			
			
			RegionUtilities_GetPositioningBounds(returnCarbonWindow(inPtr), &integerRect);
			screenRect = CGRectMake(integerRect.left, integerRect.top,
									integerRect.right - integerRect.left,
									integerRect.bottom - integerRect.top);
		}
		
		if (CGRectContainsPoint(screenRect, stackingOrigin))
		{
			// window is on the display where the user set an origin preference
			outPositionPtr->x = stackingOrigin.x + stagger.x * (1 + inLocalWindowIndex);
			outPositionPtr->y = stackingOrigin.y + stagger.y * (1 + inLocalWindowIndex);
		}
		else
		{
			// window is on a different display; use the origin magnitude to
			// determine a reasonable offset on the window’s actual display
			// (TEMPORARY; ideally the preference itself is per-display)
			stackingOrigin.x += screenRect.origin.x;
			stackingOrigin.y += screenRect.origin.y;
			outPositionPtr->x = stackingOrigin.x + stagger.x * (1 + inLocalWindowIndex);
			outPositionPtr->y = stackingOrigin.y + stagger.y * (1 + inLocalWindowIndex);
		}
	}
}// calculateIndexedWindowPosition


/*!
Calculates the stagger position of windows.

The index hints can be used to strongly suggest where
a window should end up on the screen.  (Use this if
the given window is part of an iteration over several
windows, where its order in the list is important.)
If no hints are provided, a window position is
determined in some other way.

On input, the rectangle must be the structure/frame
of the window in screen-pixel coordinates.

On output, a new frame rectangle is provided in
screen-pixel coordinates.

(4.1)
*/
void
calculateWindowPosition		(My_TerminalWindowPtr	inPtr,
							 UInt16*				inoutStaggerListIndexHintPtr,
							 UInt16*				inoutLocalWindowIndexHintPtr,
							 HIRect*				inoutArrangement)
{
	HIRect const	kStructureRegionBounds = *inoutArrangement;
	Float32 const	kStructureWidth = kStructureRegionBounds.size.width;
	Float32 const	kStructureHeight = kStructureRegionBounds.size.height;
	Rect			screenRect;
	HIPoint			structureTopLeftScrap = CGPointMake(0, 0);
	Boolean			doneCalculation = false;
	Boolean			tooFarRight = false;
	Boolean			tooFarDown = false;
	
	
	RegionUtilities_GetPositioningBounds(returnCarbonWindow(inPtr), &screenRect);
	
	while ((false == doneCalculation) && (false == tooFarRight))
	{
		calculateIndexedWindowPosition(inPtr, *inoutStaggerListIndexHintPtr, *inoutLocalWindowIndexHintPtr,
										&structureTopLeftScrap);
		inoutArrangement->origin.x = structureTopLeftScrap.x;
		inoutArrangement->origin.y = structureTopLeftScrap.y;
		inoutArrangement->size.width = kStructureWidth;
		inoutArrangement->size.height = kStructureHeight;
		
		// see if the window position would start to nudge it off
		// the bottom or right edge of its display
		tooFarRight = ((inoutArrangement->origin.x + inoutArrangement->size.width) > screenRect.right);
		tooFarDown = ((inoutArrangement->origin.y + inoutArrangement->size.height) > screenRect.bottom);
		
		if (tooFarDown)
		{
			if (0 == *inoutLocalWindowIndexHintPtr)
			{
				// the window is already offscreen despite being at the
				// stacking origin so there is nowhere else to go
				doneCalculation = true;
			}
			else
			{
				// try shifting the top-left-corner origin over to see
				// if there is still room for a new window stack
				++(*inoutStaggerListIndexHintPtr);
				*inoutLocalWindowIndexHintPtr = 0;
			}
		}
		else
		{
			doneCalculation = true;
		}
	}
}// calculateWindowPosition


/*!
Notifies all listeners for the specified Terminal
Window state change, passing the given context to
the listener.

IMPORTANT:	The context must make sense for the
			type of change; see "TerminalWindow.h"
			for the type of context associated with
			each terminal window change.

(3.0)
*/
void
changeNotifyForTerminalWindow	(My_TerminalWindowPtr	inPtr,
								 TerminalWindow_Change	inWhatChanged,
								 void*					inContextPtr)
{
	// invoke listener callback routines appropriately, from the specified terminal window’s listener model
	ListenerModel_NotifyListenersOfEvent(inPtr->changeListenerModel, inWhatChanged, inContextPtr);
}// changeNotifyForTerminalWindow


/*!
Registers the “bell off” icon reference with the system,
and returns a reference to the new icon.

(3.1)
*/
IconRef
createBellOffIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnBellOffIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemBellOff,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createBellOffIcon


/*!
Registers the “bell on” icon reference with the system,
and returns a reference to the new icon.

(3.1)
*/
IconRef
createBellOnIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnBellOnIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemBellOn,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createBellOnIcon


/*!
Registers the “customize toolbar” icon reference with the system,
and returns a reference to the new icon.

NOTE:	This is only being created for short-term Carbon use; it
		will not be necessary to allocate icons at all in Cocoa
		windows.

(4.0)
*/
IconRef
createCustomizeToolbarIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnCustomizeToolbarIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemCustomize,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createCustomizeToolbarIcon


/*!
Registers the “full screen” icon reference with the system,
and returns a reference to the new icon.

(3.1)
*/
IconRef
createFullScreenIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnFullScreenIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemFullScreen,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createFullScreenIcon


/*!
Registers the “hide window” icon reference with the system,
and returns a reference to the new icon.

(3.1)
*/
IconRef
createHideWindowIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnHideWindowIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemHideWindow,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createHideWindowIcon


/*!
Registers the “kill session” icon reference with the system,
and returns a reference to the new icon.

NOTE:	This is only being created for short-term Carbon use; it
		will not be necessary to allocate icons at all in Cocoa
		windows.

(4.0)
*/
IconRef
createKillSessionIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnKillSessionIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemKillSession,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createKillSessionIcon


/*!
Registers the “LED off” icon reference with the system,
and returns a reference to the new icon.

(3.1)
*/
IconRef
createLEDOffIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnLEDOffIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemLEDOff,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createLEDOffIcon


/*!
Registers the “LED on” icon reference with the system,
and returns a reference to the new icon.

(3.1)
*/
IconRef
createLEDOnIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnLEDOnIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemLEDOn,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createLEDOnIcon


/*!
Registers the “print” icon reference with the system, and returns
a reference to the new icon.

NOTE:	This is only being created for short-term Carbon use; it
		will not be necessary to allocate icons at all in Cocoa
		windows.

(4.0)
*/
IconRef
createPrintIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnPrintIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemPrint,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createPrintIcon


/*!
Registers the “restart session” icon reference with the system,
and returns a reference to the new icon.

NOTE:	This is only being created for short-term Carbon use; it
		will not be necessary to allocate icons at all in Cocoa
		windows.

(4.0)
*/
IconRef
createRestartSessionIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnRestartSessionIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemRestartSession,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createRestartSessionIcon


/*!
Registers the “scroll lock off” icon reference with the
system, and returns a reference to the new icon.

(3.1)
*/
IconRef
createScrollLockOffIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnScrollLockOffIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemScrollLockOff,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createScrollLockOffIcon


/*!
Registers the “scroll lock on” icon reference with the
system, and returns a reference to the new icon.

(3.1)
*/
IconRef
createScrollLockOnIcon ()
{
	IconRef		result = nullptr;
	FSRef		iconFile;
	
	
	if (AppResources_GetArbitraryResourceFileFSRef
		(AppResources_ReturnScrollLockOnIconFilenameNoExtension(),
			CFSTR("icns")/* type */, iconFile))
	{
		if (noErr != RegisterIconRefFromFSRef(AppResources_ReturnCreatorCode(),
												kConstantsRegistry_IconServicesIconToolbarItemScrollLockOn,
												&iconFile, &result))
		{
			// failed!
			result = nullptr;
		}
	}
	
	return result;
}// createScrollLockOnIcon


/*!
Creates a floating window that looks like a tab, used to
“attach” to an existing terminal window in tab view.

Also installs a resize handler to ensure the drawer is
no bigger than its default size (otherwise, the Toolbox
will make it as wide as the window).

(3.1)
*/
Boolean
createTabWindow		(My_TerminalWindowPtr	inPtr)
{
	HIWindowRef		tabWindow = nullptr;
	Boolean			result = false;
	
	
	// load the NIB containing this floater (automatically finds the right localization)
	tabWindow = NIBWindow(AppResources_ReturnBundleForNIBs(),
							CFSTR("TerminalWindow"), CFSTR("Tab")) << NIBLoader_AssertWindowExists;
	if (nullptr != tabWindow)
	{
		OSStatus	error = noErr;
		Rect		currentBounds;
		
		
		// install a callback that responds as the drawer window is resized; this is used
		// primarily to enforce a maximum drawer width, not to allow a resizable drawer;
		// these are also only initial values, they are updated later if anything resizes
		error = GetWindowBounds(tabWindow, kWindowContentRgn, &currentBounds);
		assert_noerr(error);
		inPtr->tabDrawerWindowResizeHandler.install(tabWindow, handleNewDrawerWindowSize, inPtr->selfRef/* user data */,
													currentBounds.right - currentBounds.left/* minimum width */,
													currentBounds.bottom - currentBounds.top/* minimum height */,
													currentBounds.right - currentBounds.left/* maximum width */,
													currentBounds.bottom - currentBounds.top/* maximum height */);
		assert(inPtr->tabDrawerWindowResizeHandler.isInstalled());
		
		// if the global default width has not yet been initialized, set it;
		// initialize this window’s tab size field to the global default
		if (0.0 == gDefaultTabWidth)
		{
			error = GetWindowBounds(tabWindow, kWindowStructureRgn, &currentBounds);
			assert_noerr(error);
			gDefaultTabWidth = STATIC_CAST(currentBounds.right - currentBounds.left, Float32);
			gDefaultTabHeight = STATIC_CAST(currentBounds.bottom - currentBounds.top, Float32);
		}
		{
			OptionBits				preferredEdge = kWindowEdgeTop;
			Preferences_Result		prefsResult = Preferences_GetData(kPreferences_TagWindowTabPreferredEdge,
																		sizeof(preferredEdge), &preferredEdge);
			
			
			if (kPreferences_ResultOK != prefsResult)
			{
				preferredEdge = kWindowEdgeTop;
			}
			if ((kWindowEdgeLeft == preferredEdge) || (kWindowEdgeRight == preferredEdge))
			{
				inPtr->tabSizeInPixels = gDefaultTabHeight;
			}
			else
			{
				inPtr->tabSizeInPixels = gDefaultTabWidth;
			}
		}
		
		// enable drag tracking so that tabs can auto-activate during drags
		error = SetAutomaticControlDragTrackingEnabledForWindow(tabWindow, true/* enabled */);
		assert_noerr(error);
		
		// install a drag handler so that tabs switch automatically as
		// items hover over them
		{
			HIViewRef	contentPane = nullptr;
			
			
			error = HIViewFindByID(HIViewGetRoot(tabWindow), kHIViewWindowContentID, &contentPane);
			assert_noerr(error);
			inPtr->tabDragHandlerPtr = new CarbonEventHandlerWrap(HIViewGetEventTarget(contentPane),
																	receiveTabDragDrop,
																	CarbonEventSetInClass
																	(CarbonEventClass(kEventClassControl),
																		kEventControlDragEnter),
																	inPtr->selfRef/* handler data */);
			assert(nullptr != inPtr->tabDragHandlerPtr);
			assert(inPtr->tabDragHandlerPtr->isInstalled());
			error = SetControlDragTrackingEnabled(contentPane, true/* is drag enabled */);
			assert_noerr(error);
		}
	}
	
	inPtr->tab.setWithRetain(tabWindow);
	result = (nullptr != tabWindow);
	
	return result;
}// createTabWindow


/*!
Creates the content controls (except the terminal screen
itself) in the specified terminal window, for which a
Mac OS window must already exist.  The controls include
the scroll bars and the toolbar.

(3.0)
*/
void
createViews		(My_TerminalWindowPtr	inPtr)
{
	HIViewWrap	contentView(kHIViewWindowContentID, returnCarbonWindow(inPtr));
	Rect		rect;
	OSStatus	error = noErr;
	
	
	assert(contentView.exists());
	
	// create routine to handle scroll activity
	inPtr->scrollProcUPP = NewControlActionUPP(scrollProc); // this is disposed via TerminalWindow_Dispose()
	
	// create a vertical scroll bar; the resize event handler initializes its size correctly
	bzero(&rect, sizeof(rect));
	error = CreateScrollBarControl(returnCarbonWindow(inPtr), &rect, 0/* value */, 0/* minimum */, 0/* maximum */, 0/* view size */,
									true/* live tracking */, inPtr->scrollProcUPP, &inPtr->controls.scrollBarV);
	assert_noerr(error);
	error = SetControlProperty(inPtr->controls.scrollBarV, AppResources_ReturnCreatorCode(),
								kConstantsRegistry_ControlPropertyTypeTerminalWindowRef,
								sizeof(inPtr->selfRef), &inPtr->selfRef); // used in scrollProc
	assert_noerr(error);
	error = HIViewAddSubview(contentView, inPtr->controls.scrollBarV);
	assert_noerr(error);
	
	// create a horizontal scroll bar; the resize event handler initializes its size correctly
	bzero(&rect, sizeof(rect));
	error = CreateScrollBarControl(returnCarbonWindow(inPtr), &rect, 0/* value */, 0/* minimum */, 0/* maximum */, 0/* view size */,
									true/* live tracking */, inPtr->scrollProcUPP, &inPtr->controls.scrollBarH);
	assert_noerr(error);
	error = SetControlProperty(inPtr->controls.scrollBarH, AppResources_ReturnCreatorCode(),
								kConstantsRegistry_ControlPropertyTypeTerminalWindowRef,
								sizeof(inPtr->selfRef), &inPtr->selfRef); // used in scrollProc
	assert_noerr(error);
	error = HIViewAddSubview(contentView, inPtr->controls.scrollBarH);
	assert_noerr(error);
	// horizontal scrolling is not supported for now...
	UNUSED_RETURN(OSStatus)HIViewSetVisible(inPtr->controls.scrollBarH, false);
}// createViews


/*!
Creates a Cocoa window for the specified terminal window,
based on a Carbon window (for now), and constructs a root
view for subsequent embedding.

Returns nullptr if the window was not created successfully.

(4.0)
*/
NSWindow*
createWindow ()
{
@autoreleasepool {
	NSWindow*		result = nil;
	HIWindowRef		window = nullptr;
	Boolean			useCustomFullScreenMode = false;
	
	
	// load the NIB containing this window (automatically finds the right localization)
	window = NIBWindow(AppResources_ReturnBundleForNIBs(),
						CFSTR("TerminalWindow"), CFSTR("Window")) << NIBLoader_AssertWindowExists;
	if (nullptr != window)
	{
		result = CocoaBasic_ReturnNewOrExistingCocoaCarbonWindow(window);
		
		// override this default; technically terminal windows
		// are immediately closeable for the first 15 seconds
		UNUSED_RETURN(OSStatus)SetWindowModified(window, false);
		
		if (kPreferences_ResultOK !=
			Preferences_GetData(kPreferences_TagKioskNoSystemFullScreenMode, sizeof(useCustomFullScreenMode),
								&useCustomFullScreenMode))
		{
			useCustomFullScreenMode = false; // assume a default if preference can’t be found
		}
		
		if (false == useCustomFullScreenMode)
		{
			setCarbonWindowFullScreenIcon(window, true);
		}
	}
	return result;
}// @autoreleasepool
}// createWindow


/*!
Returns the screen buffer used by the view most recently
focused by the user.  Therefore, even if no view is
currently focused, some valid screen buffer will be
returned as long as SOME screen is used by the window
(which should always be true!).

IMPORTANT:	This API is under evaluation.  Perhaps there
			will be value in allowing more than one screen
			buffer per view, in which case returning just
			one would be too limiting.

(3.0)
*/
TerminalScreenRef
getActiveScreen		(My_TerminalWindowPtr	inPtr)
{
	assert(!inPtr->allScreens.empty());
	return inPtr->allScreens.front(); // TEMPORARY; should instead use focus-change events from terminal views
}// getActiveScreen


/*!
Returns the view most recently focused by the user.
Therefore, even if no view is currently focused, some
valid view will be returned as long as SOME view exists
in the window (which should always be true!).

(3.0)
*/
TerminalViewRef
getActiveView	(My_TerminalWindowPtr	inPtr)
{
	assert(!inPtr->allViews.empty());
	return inPtr->allViews.front(); // TEMPORARY; should instead use focus-change events from terminal views
}// getActiveView


/*!
Returns a constant describing the type of scroll bar that is
given.  If the specified control does not belong to the given
terminal window, "kMy_InvalidScrollBarKind" is returned;
otherwise, a constant is returned indicating whether the
control is horizontal or vertical.

(3.0)
*/
My_ScrollBarKind
getScrollBarKind	(My_TerminalWindowPtr	inPtr,
					 HIViewRef				inScrollBarControl)
{
	My_ScrollBarKind	result = kMy_InvalidScrollBarKind;
	
	
	if (inScrollBarControl == inPtr->controls.scrollBarH) result = kMy_ScrollBarKindHorizontal;
	if (inScrollBarControl == inPtr->controls.scrollBarV) result = kMy_ScrollBarKindVertical;
	return result;
}// getScrollBarKind


/*!
Returns the view that the given scroll bar controls,
or nullptr if none.

(3.0)
*/
TerminalViewRef
getScrollBarView	(My_TerminalWindowPtr	inPtr,
					 HIViewRef				UNUSED_ARGUMENT(inScrollBarControl))
{
	assert(!inPtr->allViews.empty());
	return inPtr->allViews.front(); // one day, if more than one view per window exists, this logic will be more complex
}// getScrollBarView


/*!
Returns the width and height of the screen interior
(i.e. not including insets) of a terminal window
whose content region has the specified dimensions.
The resultant dimensions subtract out the size of any
window header (unless it’s collapsed), the scroll
bars, and the terminal screen insets (padding).

See also getWindowSizeFromViewSize(), which does the
reverse.

IMPORTANT:	Any changes to this routine should be
			reflected inversely in the code for
			getWindowSizeFromViewSize().

(3.0)
*/
void
getViewSizeFromWindowSize	(My_TerminalWindowPtr	inPtr,
							 SInt16					inWindowContentWidthInPixels,
							 SInt16					inWindowContentHeightInPixels,
							 SInt16*				outScreenInteriorWidthInPixels,
							 SInt16*				outScreenInteriorHeightInPixels)
{
	if (nullptr != outScreenInteriorWidthInPixels)
	{
		*outScreenInteriorWidthInPixels = inWindowContentWidthInPixels - returnScrollBarWidth(inPtr);
	}
	if (nullptr != outScreenInteriorHeightInPixels)
	{
		*outScreenInteriorHeightInPixels = inWindowContentHeightInPixels - returnStatusBarHeight(inPtr) -
											returnToolbarHeight(inPtr) - returnScrollBarHeight(inPtr);
	}
}// getViewSizeFromWindowSize


/*!
Returns the width and height of the content region
of a terminal window whose screen interior has the
specified dimensions.

See also getViewSizeFromWindowSize(), which does
the reverse.

IMPORTANT:	Any changes to this routine should be
			reflected inversely in the code for
			getViewSizeFromWindowSize().

(3.0)
*/
void
getWindowSizeFromViewSize	(My_TerminalWindowPtr	inPtr,
							 SInt16					inScreenInteriorWidthInPixels,
							 SInt16					inScreenInteriorHeightInPixels,
							 SInt16*				outWindowContentWidthInPixels,
							 SInt16*				outWindowContentHeightInPixels)
{
	if (nullptr != outWindowContentWidthInPixels)
	{
		*outWindowContentWidthInPixels = inScreenInteriorWidthInPixels + returnScrollBarWidth(inPtr);
	}
	if (nullptr != outWindowContentHeightInPixels)
	{
		*outWindowContentHeightInPixels = inScreenInteriorHeightInPixels + returnStatusBarHeight(inPtr) +
											returnToolbarHeight(inPtr) + returnScrollBarHeight(inPtr);
	}
}// getWindowSizeFromViewSize


/*!
Responds to a close of the Find dialog sheet in a terminal
window.  Currently, this just retains the keyword string
so that Find Again can be used, and remembers the user’s
most recent checkbox settings.

(3.0)
*/
void
handleFindDialogClose	(FindDialog_Ref		inDialogThatClosed)
{
	TerminalWindowRef		terminalWindow = FindDialog_ReturnTerminalWindow(inDialogThatClosed);
	
	
	if (terminalWindow != nullptr)
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
		
		
		// save things the user entered in the dialog
		// (history array is implicitly saved because
		// the mutable array given at construction is
		// retained by reference)
		ptr->recentSearchOptions = FindDialog_ReturnOptions(inDialogThatClosed);
	}
}// handleFindDialogClose


/*!
This routine is called whenever the tab is resized, and it
should resize and relocate views as appropriate.

Even if this implementation does nothing, it must exist so the
drawer height (or width, for vertical tabs) is constrained.

(3.1)
*/
void
handleNewDrawerWindowSize	(WindowRef		inWindowRef,
							 Float32		inDeltaX,
							 Float32		UNUSED_ARGUMENT(inDeltaY),
							 void*			UNUSED_ARGUMENT(inContext))
{
	HIViewWrap		viewWrap;
	
	
	// resize the title view, and move the pop-out button
	if (Localization_IsLeftToRight())
	{
		viewWrap = HIViewWrap(idMyLabelTabTitle, inWindowRef);
		viewWrap << HIViewWrap_DeltaSize(inDeltaX, 0);
	}
	else
	{
		viewWrap = HIViewWrap(idMyLabelTabTitle, inWindowRef);
		viewWrap << HIViewWrap_DeltaSize(inDeltaX, 0);
	}
}// handleNewDrawerWindowSize


/*!
This method moves and resizes the contents of a terminal
window in response to a resize.

(3.0)
*/
void
handleNewSize	(WindowRef	inWindow,
				 Float32	UNUSED_ARGUMENT(inDeltaX),
				 Float32	UNUSED_ARGUMENT(inDeltaY),
				 void*		inTerminalWindowRef)
{
	TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inTerminalWindowRef, TerminalWindowRef);
	HIRect				contentBounds;
	OSStatus			error = noErr;
	
	
	// get window boundaries in local coordinates
	error = HIViewGetBounds(HIViewWrap(kHIViewWindowContentID, inWindow), &contentBounds);
	assert_noerr(error);
	
	if (terminalWindow != nullptr)
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
		HIRect							viewBounds;
		
		
		// glue the vertical scroll bar to the new right side of the window and to the
		// bottom edge of the status bar, and ensure it is glued to the size box in the
		// corner (so vertically resize it)
		viewBounds.origin.x = contentBounds.size.width - returnScrollBarWidth(ptr);
		viewBounds.origin.y = -1; // frame thickness
		viewBounds.size.width = returnScrollBarWidth(ptr);
		viewBounds.size.height = contentBounds.size.height - returnGrowBoxHeight(ptr);
		error = HIViewSetFrame(ptr->controls.scrollBarV, &viewBounds);
		assert_noerr(error);
		
		// glue the horizontal scroll bar to the new bottom edge of the window; it must
		// also move because its left edge is glued to the window edge, and it must resize
		// because its right edge is glued to the size box in the corner
		viewBounds.origin.x = -1; // frame thickness
		viewBounds.origin.y = contentBounds.size.height - returnScrollBarHeight(ptr);
		viewBounds.size.width = contentBounds.size.width - returnGrowBoxWidth(ptr);
		viewBounds.size.height = returnScrollBarHeight(ptr);
		UNUSED_RETURN(OSStatus)HIViewSetFrame(ptr->controls.scrollBarH, &viewBounds); // ignore error since scroll bar is unused
		
		// change the screen sizes to match the user’s window size as well as possible,
		// notifying listeners of the change (to trigger actions such as sending messages
		// to the Unix process in the window, etc.); the number of columns in each screen
		// will be changed to closely match the overall width, but only the last screen’s
		// line count will be changed; in the event that there are tabs, only views
		// belonging to the same group will be scaled together during the resizing
		{
			TerminalWindow_ViewGroup const	kViewGroupArray[] =
											{
												kTerminalWindow_ViewGroupEverything
											};
			UInt16 const					kNumberOfViews = TerminalWindow_ReturnViewCount(terminalWindow);
			TerminalViewRef*				viewArray = new TerminalViewRef[kNumberOfViews];
			SInt16							groupIndex = 0;
			
			
			for (groupIndex = 0; groupIndex < STATIC_CAST(sizeof(kViewGroupArray) / sizeof(TerminalWindow_ViewGroup), SInt16); ++groupIndex)
			{
				SInt16		i = 0;
				UInt16		actualNumberOfViews = 0;
				
				
				// find all the views belonging to this tab and apply the resize
				// algorithm only while considering views belonging to the same tab
				TerminalWindow_GetViewsInGroup(terminalWindow, kViewGroupArray[groupIndex], kNumberOfViews, viewArray,
												&actualNumberOfViews);
				if (actualNumberOfViews > 0)
				{
					HIRect		terminalScreenBounds;
					
					
					for (i = 0; i < actualNumberOfViews; ++i)
					{
						// figure out how big the screen is becoming;
						// TEMPORARY: sets each view size to the whole area, since there is only one right now
						//getViewSizeFromWindowSize(ptr, contentBounds.right - contentBounds.left,
						//							contentBounds.bottom - contentBounds.top,
						//							&terminalScreenWidth, &terminalScreenHeight);
						
						// make the view stick to the scroll bars, effectively adding perhaps a few pixels of padding
						{
							HIRect		scrollBarBounds;
							
							
							error = HIViewGetFrame(TerminalView_ReturnContainerHIView(viewArray[i]), &terminalScreenBounds);
							assert_noerr(error);
							error = HIViewGetFrame(ptr->controls.scrollBarV, &scrollBarBounds);
							assert_noerr(error);
							terminalScreenBounds.origin.x = -1/* frame thickness */;
							terminalScreenBounds.origin.y = -1/* frame thickness */;
							terminalScreenBounds.size.width = scrollBarBounds.origin.x - terminalScreenBounds.origin.x;
							error = HIViewGetFrame(ptr->controls.scrollBarH, &scrollBarBounds);
							assert_noerr(error);
							terminalScreenBounds.size.height = scrollBarBounds.origin.y - terminalScreenBounds.origin.y;
						}
						error = HIViewSetFrame(TerminalView_ReturnContainerHIView(viewArray[i]), &terminalScreenBounds);
						assert_noerr(error);
					}
				}
			}
			delete [] viewArray, viewArray = nullptr;
		}
		
		// when the window size changes, the screen dimensions are likely to change
		// TEMPORARY: analyze this further, see if this behavior is really desirable
		changeNotifyForTerminalWindow(ptr, kTerminalWindow_ChangeScreenDimensions, terminalWindow/* context */);
		
		// update the scroll bars’ values to reflect the new screen size
		updateScrollBars(ptr);
	}
}// handleNewSize


/*!
Installs a handler to draw tick marks on top of the
standard scroll bar (for showing the location of search
results).

This handler is not always installed because it is only
needed while there are search results defined, and there
is a cost to allowing scroll bar draws to enter the
application’s memory space.

To remove, call inPtr->scrollTickHandler.remove().

(4.0)
*/
void
installTickHandler	(My_TerminalWindowPtr	inPtr)
{
	inPtr->scrollTickHandler.remove();
	assert(false == inPtr->scrollTickHandler.isInstalled());
	inPtr->scrollTickHandler.install(HIViewGetEventTarget(inPtr->controls.scrollBarV), receiveScrollBarDraw,
										CarbonEventSetInClass(CarbonEventClass(kEventClassControl), kEventControlDraw),
										inPtr->selfRef/* user data */);
	assert(inPtr->scrollTickHandler.isInstalled());
}// installTickHandler


/*!
Installs an Undo procedure that will revert
the font and/or font size of the specified
screen to its current font and/or font size
when the user chooses Undo.

(3.0)
*/
void
installUndoFontSizeChanges	(TerminalWindowRef	inTerminalWindow,
							 Boolean			inUndoFont,
							 Boolean			inUndoFontSize)
{
	OSStatus					error = noErr;
	UndoDataFontSizeChangesPtr	dataPtr = new UndoDataFontSizeChanges;	// must be allocated by "new" because it contains C++ classes;
																		// disposed in the action method
	
	
	if (dataPtr == nullptr) error = memFullErr;
	else
	{
		// initialize context structure
		CFStringRef		fontName = nullptr;
		
		
		dataPtr->terminalWindow = inTerminalWindow;
		dataPtr->undoFontSize = inUndoFontSize;
		dataPtr->undoFont = inUndoFont;
		TerminalWindow_GetFontAndSize(inTerminalWindow, &fontName, &dataPtr->fontSize);
		dataPtr->fontName.setWithRetain(fontName);
	}
	{
		CFStringRef		undoNameCFString = nullptr;
		CFStringRef		redoNameCFString = nullptr;
		
		
		assert(UIStrings_Copy(kUIStrings_UndoFormatChanges, undoNameCFString).ok());
		assert(UIStrings_Copy(kUIStrings_RedoFormatChanges, redoNameCFString).ok());
		dataPtr->action = Undoables_NewAction(undoNameCFString, redoNameCFString, reverseFontChanges,
												kUndoableContextIdentifierTerminalFontSizeChanges, dataPtr);
		if (nullptr != undoNameCFString) CFRelease(undoNameCFString), undoNameCFString = nullptr;
		if (nullptr != redoNameCFString) CFRelease(redoNameCFString), redoNameCFString = nullptr;
	}
	Undoables_AddAction(dataPtr->action);
	if (error != noErr) Console_WriteValue("Warning: Could not make font and/or size change undoable, error", error);
	else
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inTerminalWindow);
		
		
		ptr->installedActions.push_back(dataPtr->action);
	}
}// installUndoFontSizeChanges


/*!
Installs an Undo procedure that will revert the
dimensions of the of the specified screen to its
current dimensions when the user chooses Undo.

(3.1)
*/
void
installUndoScreenDimensionChanges	(TerminalWindowRef		inTerminalWindow)
{
	OSStatus							error = noErr;
	UndoDataScreenDimensionChangesPtr	dataPtr = new UndoDataScreenDimensionChanges;	// disposed in the action method
	
	
	if (dataPtr == nullptr) error = memFullErr;
	else
	{
		// initialize context structure
		dataPtr->terminalWindow = inTerminalWindow;
		TerminalWindow_GetScreenDimensions(inTerminalWindow, &dataPtr->columns, &dataPtr->rows);
	}
	{
		CFStringRef		undoNameCFString = nullptr;
		CFStringRef		redoNameCFString = nullptr;
		
		
		assert(UIStrings_Copy(kUIStrings_UndoDimensionChanges, undoNameCFString).ok());
		assert(UIStrings_Copy(kUIStrings_RedoDimensionChanges, redoNameCFString).ok());
		dataPtr->action = Undoables_NewAction(undoNameCFString, redoNameCFString, reverseScreenDimensionChanges,
												kUndoableContextIdentifierTerminalDimensionChanges, dataPtr);
		if (nullptr != undoNameCFString) CFRelease(undoNameCFString), undoNameCFString = nullptr;
		if (nullptr != redoNameCFString) CFRelease(redoNameCFString), redoNameCFString = nullptr;
	}
	Undoables_AddAction(dataPtr->action);
	if (error != noErr) Console_WriteValue("Warning: Could not make dimension change undoable, error", error);
	else
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), inTerminalWindow);
		
		
		ptr->installedActions.push_back(dataPtr->action);
	}
}// installUndoScreenDimensionChanges


/*!
A comparison routine that is compatible with std::sort();
returns true if the first window is strictly less-than
the second based on whether or not "inWindow1" covers a
strictly larger pixel area.

(4.1)
*/
bool
lessThanIfGreaterArea	(HIWindowRef	inWindow1,
						 HIWindowRef	inWindow2)
{
	bool	result = false;
	Rect	structureBounds1;
	Rect	structureBounds2;
	
	
	if ((noErr == GetWindowBounds(inWindow1, kWindowStructureRgn, &structureBounds1)) &&
		(noErr == GetWindowBounds(inWindow2, kWindowStructureRgn, &structureBounds2)))
	{
		UInt32 const	kArea1 = ((structureBounds1.right - structureBounds1.left) *
									(structureBounds1.bottom - structureBounds1.top));
		UInt32 const	kArea2 = ((structureBounds2.right - structureBounds2.left) *
									(structureBounds2.bottom - structureBounds2.top));
		
		
		result = (kArea1 > kArea2);
	}
	
	return result;
}// lessThanIfGreaterArea


/*!
Handles "kEventCommandProcess" of "kEventClassCommand" for
terminal window commands.

(3.0)
*/
OSStatus
receiveHICommand	(EventHandlerCallRef	UNUSED_ARGUMENT(inHandlerCallRef),
					 EventRef				inEvent,
					 void*					inTerminalWindowRef)
{
	OSStatus			result = eventNotHandledErr;
	TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inTerminalWindowRef, TerminalWindowRef);
	UInt32 const		kEventClass = GetEventClass(inEvent);
	UInt32 const		kEventKind = GetEventKind(inEvent);
	
	
	assert(kEventClass == kEventClassCommand);
	{
		HICommand	received;
		
		
		// determine the command in question
		result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamDirectObject, typeHICommand, received);
		
		// if the command information was found, proceed
		if (result == noErr)
		{
			// don’t claim to have handled any commands not shown below
			result = eventNotHandledErr;
			
			switch (kEventKind)
			{
			case kEventCommandProcess:
				// Execute a command selected from a menu (or sent from a control, etc.).
				//
				// IMPORTANT: This could imply ANY form of menu selection, whether from
				//            the menu bar, from a contextual menu, or from a pop-up menu!
				switch (received.commandID)
				{
				case kCommandFind:
					// enter search mode
					TerminalWindow_DisplayTextSearchDialog(terminalWindow);
					result = noErr;
					break;
				
				case kCommandFindAgain:
				case kCommandFindPrevious:
					// rotate to next or previous match; since ALL matches are highlighted at
					// once, this is simply a focusing mechanism and does not conduct a search
					{
						TerminalViewRef		view = TerminalWindow_ReturnViewWithFocus(terminalWindow);
						Boolean				noAnimations = false;
						
						
						// determine if animation should occur
						unless (kPreferences_ResultOK ==
								Preferences_GetData(kPreferences_TagNoAnimations,
													sizeof(noAnimations), &noAnimations))
						{
							noAnimations = false; // assume a value, if preference can’t be found
						}
						
						TerminalView_RotateSearchResultHighlight(view, (kCommandFindPrevious == received.commandID) ? -1 : +1);
						
						unless (noAnimations)
						{
							TerminalView_ZoomToSearchResults(view);
						}
					}
					result = noErr;
					break;
				
				case kCommandFindCursor:
					// draw attention to terminal cursor location
					TerminalView_ZoomToCursor(TerminalWindow_ReturnViewWithFocus(terminalWindow));
					result = noErr;
					break;
				
				case kCommandBiggerText:
				case kCommandSmallerText:
					{
						UInt16		fontSize = 0;
						
						
						// determine the new font size
						TerminalWindow_GetFontAndSize(terminalWindow, nullptr/* font */, &fontSize);
						if (kCommandBiggerText == received.commandID) ++fontSize;
						else if (kCommandSmallerText == received.commandID)
						{
							if (fontSize > 4/* arbitrary */) --fontSize;
						}
						
						// set the window size to fit the new font size optimally
						installUndoFontSizeChanges(terminalWindow, false/* undo font */, true/* undo font size */);
						TerminalWindow_SetFontAndSize(terminalWindow, nullptr/* font */, fontSize);
						
						result = noErr;
					}
					break;
				
				case kCommandFullScreenToggle:
					{
						// transition active window into or out of full-screen mode
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						// NOTE: while it would be more consistent to require the Control key,
						// this isn't really possible (it would cause problems when trying to
						// Control-click the Full Screen toolbar icon, and it would cause the
						// default Control-command-F key equivalent to always trigger a swap);
						// so a Full Screen preference swap requires Option, even though the
						// equivalent behavior during a window resize requires the Control key
						Boolean const					kSwapModes = EventLoop_IsOptionKeyDown();
						
						
						setTerminalWindowFullScreen(ptr, false == TerminalWindow_IsFullScreen(terminalWindow), kSwapModes);
						
						result = noErr;
					}
					break;
				
				case kCommandZoomMaximumSize:
					{
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						Rect							maxBounds;
						TerminalView_DisplayMode const	kOldMode = TerminalView_ReturnDisplayMode(ptr->allViews.front());
						
						
						// zoom the window to the largest possible size; this can be
						// done by choosing the largest possible window frame and
						// temporarily pretending that the view should zoom its text
						RegionUtilities_GetWindowMaximumBounds(returnCarbonWindow(ptr), &maxBounds,
																nullptr/* previous bounds */, true/* no insets */);
						installUndoFontSizeChanges(ptr->selfRef, false/* undo font */, true/* undo font size */);
						TerminalView_SetDisplayMode(ptr->allViews.front(), kTerminalView_DisplayModeZoom);
						setViewSizeIndependentFromWindow(ptr, true);
						UNUSED_RETURN(OSStatus)SetWindowBounds(returnCarbonWindow(ptr), kWindowContentRgn, &maxBounds);
						setViewSizeIndependentFromWindow(ptr, false);
						TerminalView_SetDisplayMode(ptr->allViews.front(), kOldMode);
						
						result = noErr;
					}
					break;
				
				case kCommandFormatDefault:
					{
						// reformat frontmost window using the Default preferences
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						Preferences_ContextRef			defaultSettings = nullptr;
						
						
						if (kPreferences_ResultOK == Preferences_GetDefaultContext(&defaultSettings, Quills::Prefs::FORMAT))
						{
							setViewFormatPreferences(ptr, defaultSettings);
						}
						
						result = noErr;
					}
					break;
				
				case kCommandFormatByFavoriteName:
					// IMPORTANT: This implementation is for Carbon compatibility only, as the
					// Session Preferences panel is still Carbon-based and has a menu that
					// relies on this command handler.  The equivalent menu bar command does
					// not use this, it has an associated Objective-C action method.
					{
						// reformat frontmost window using the specified preferences
						if (received.attributes & kHICommandFromMenu)
						{
							My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
							CFStringRef						collectionName = nullptr;
							
							
							if ((noErr == CopyMenuItemTextAsCFString(received.menu.menuRef, received.menu.menuItemIndex, &collectionName)) &&
								Preferences_IsContextNameInUse(Quills::Prefs::FORMAT, collectionName))
							{
								Preferences_ContextWrap		namedSettings(Preferences_NewContextFromFavorites
																			(Quills::Prefs::FORMAT, collectionName),
																			Preferences_ContextWrap::kAlreadyRetained);
								
								
								if (namedSettings.exists())
								{
									setViewFormatPreferences(ptr, namedSettings.returnRef());
								}
								CFRelease(collectionName), collectionName = nullptr;
							}
						}
						
						result = noErr;
					}
					break;
				
				case kCommandFormat:
					{
						// display a format customization dialog
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						Preferences_ContextRef			temporaryContext = sheetContextBegin(ptr, Quills::Prefs::FORMAT,
																								kMy_SheetTypeFormat);
						
						
						if (nullptr == temporaryContext)
						{
							Sound_StandardAlert();
							Console_Warning(Console_WriteLine, "failed to construct temporary sheet context");
						}
						else
						{
							GenericDialog_Wrap				dialog;
							PrefPanelFormats_ViewManager*	embeddedPanel = [[PrefPanelFormats_ViewManager alloc] init];
							CFRetainRelease					addToPrefsString(UIStrings_ReturnCopy(kUIStrings_PreferencesWindowAddToFavoritesButton),
																				CFRetainRelease::kAlreadyRetained);
							CFRetainRelease					cancelString(UIStrings_ReturnCopy(kUIStrings_ButtonCancel),
																			CFRetainRelease::kAlreadyRetained);
							CFRetainRelease					okString(UIStrings_ReturnCopy(kUIStrings_ButtonOK),
																		CFRetainRelease::kAlreadyRetained);
							
							
							// display the sheet
							dialog = GenericDialog_Wrap(GenericDialog_NewParentCarbon(TerminalWindow_ReturnWindow(terminalWindow),
																						embeddedPanel, temporaryContext),
														GenericDialog_Wrap::kAlreadyRetained);
							[embeddedPanel release], embeddedPanel = nil; // panel is retained by the call above
							GenericDialog_SetItemTitle(dialog.returnRef(), kGenericDialog_ItemIDButton1, okString.returnCFStringRef());
							GenericDialog_SetItemResponseBlock(dialog.returnRef(), kGenericDialog_ItemIDButton1,
																^{ sheetClosed(dialog.returnRef(), true/* is OK */); });
							GenericDialog_SetItemTitle(dialog.returnRef(), kGenericDialog_ItemIDButton2, cancelString.returnCFStringRef());
							GenericDialog_SetItemResponseBlock(dialog.returnRef(), kGenericDialog_ItemIDButton2,
																^{ sheetClosed(dialog.returnRef(), false/* is OK */); });
							GenericDialog_SetItemTitle(dialog.returnRef(), kGenericDialog_ItemIDButton3, addToPrefsString.returnCFStringRef());
							GenericDialog_SetItemResponseBlock(dialog.returnRef(), kGenericDialog_ItemIDButton3,
																^{
																	Preferences_TagSetRef	tagSet = PrefPanelFormats_NewTagSet();
																	
																	
																	PrefsWindow_AddCollection(temporaryContext, tagSet,
																								kCommandDisplayPrefPanelFormats);
																	Preferences_ReleaseTagSet(&tagSet);
																});
							GenericDialog_SetImplementation(dialog.returnRef(), terminalWindow);
							// TEMPORARY; maybe TerminalWindow_Retain/Release concept needs
							// to be implemented and called here; for now, assume that the
							// terminal window will remain valid as long as the dialog exists
							// (that ought to be the case)
							GenericDialog_Display(dialog.returnRef(), true/* animated */, ^{}); // retains dialog until it is dismissed
						}
						
						result = noErr;
					}
					break;
				
				case kCommandHideFrontWindow:
					// hide the frontmost terminal window from view
					TerminalWindow_SetObscured(terminalWindow, true);
					result = noErr;
					break;
				
				case kCommandHideOtherWindows:
					// hide all except the frontmost terminal window from view
					if (TerminalWindow_ReturnWindow(terminalWindow) != GetUserFocusWindow())
					{
						TerminalWindow_SetObscured(terminalWindow, true);
						
						// since every terminal window installs a handler for this command,
						// pretending this event was not handled allows the next window to
						// be notified; in effect, returning this value causes all windows
						// to be hidden automatically as a side effect of notifying listeners!
						result = eventNotHandledErr;
					}
					break;
				
				case kCommandWiderScreen:
				case kCommandNarrowerScreen:
				case kCommandTallerScreen:
				case kCommandShorterScreen:
					{
						TerminalScreenRef	activeScreen = TerminalWindow_ReturnScreenWithFocus(terminalWindow);
						UInt16				columns = Terminal_ReturnColumnCount(activeScreen);
						UInt16				rows = Terminal_ReturnRowCount(activeScreen);
						
						
						if (received.commandID == kCommandNarrowerScreen)
						{
							columns -= 4; // arbitrary delta
						}
						else if (received.commandID == kCommandTallerScreen)
						{
							rows += 2; // arbitrary delta
						}
						else if (received.commandID == kCommandShorterScreen)
						{
							rows -= 2; // arbitrary delta
						}
						else
						{
							columns += 4; // arbitrary delta
						}
						
						// arbitrarily restrict the minimum size
						if (columns < 10)
						{
							columns = 10;
						}
						if (rows < 10)
						{
							rows = 10;
						}
						
						// resize the screen and the window
						TerminalWindow_SetScreenDimensions(terminalWindow, columns, rows, true/* recordable */);
						
						// if the resulting window is close to a screen edge (less than
						// the space of a terminal row or column), snap to the screen edge
						{
							HIWindowRef		windowRef = TerminalWindow_ReturnWindow(terminalWindow);
							HIRect			frameBounds;
							HIRect			screenBounds;
							
							
							if ((noErr == HIWindowGetBounds(windowRef, kWindowStructureRgn,
															kHICoordSpaceScreenPixel, &frameBounds)) &&
								(noErr == HIWindowGetGreatestAreaDisplay(windowRef, kWindowStructureRgn,
																			kHICoordSpaceScreenPixel,
																			nullptr/* display ID */,
																			&screenBounds)))
							{
								Float32 const	kRightPad = ((screenBounds.origin.x + screenBounds.size.width) -
																(frameBounds.origin.x + frameBounds.size.width));
								Float32 const	kBottomPad = ((screenBounds.origin.y + screenBounds.size.height) -
																(frameBounds.origin.y + frameBounds.size.height));
								Boolean			autoResize = false;
								
								
								if (kRightPad < 15/* arbitrary */)
								{
									frameBounds.size.width += kRightPad;
									autoResize = true;
								}
								
								if (kBottomPad < 15/* arbitrary */)
								{
									frameBounds.size.height += kBottomPad;
									autoResize = true;
								}
								
								if (autoResize)
								{
									UNUSED_RETURN(OSStatus)HIWindowSetBounds(windowRef, kWindowStructureRgn,
																				kHICoordSpaceScreenPixel,
																				&frameBounds);
								}
							}
						}
						
						result = noErr;
					}
					break;
				
				case kCommandLargeScreen:
				case kCommandSmallScreen:
				case kCommandTallScreen:
					{
						UInt16		columns = 0;
						UInt16		rows = 0;
						
						
						// NOTE: Currently these are arbitrary, primarily because
						// certain terminals like VT100 *must* have these quick
						// switch commands available at specific dimensions of
						// 132 and 80 column widths.  However, this could be
						// expanded in the future to allow user-customized sets
						// of dimensions as well.
						if (received.commandID == kCommandLargeScreen)
						{
							columns = 132;
							rows = 24;
						}
						else if (received.commandID == kCommandTallScreen)
						{
							columns = 80;
							rows = 40;
						}
						else
						{
							columns = 80;
							rows = 24;
						}
						
						// resize the screen and the window
						installUndoScreenDimensionChanges(terminalWindow);
						TerminalWindow_SetScreenDimensions(terminalWindow, columns, rows, true/* recordable */);
						
						result = noErr;
					}
					break;
				
				case kCommandSetScreenSize:
					{
						// display a screen size customization dialog
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						Preferences_ContextRef			temporaryContext = sheetContextBegin(ptr, Quills::Prefs::TERMINAL,
																								kMy_SheetTypeScreenSize);
						
						
						if (nullptr == temporaryContext)
						{
							Sound_StandardAlert();
							Console_Warning(Console_WriteLine, "failed to construct temporary sheet context");
						}
						else
						{
							GenericDialog_Wrap						dialog;
							PrefPanelTerminals_ScreenViewManager*	embeddedPanel = [[PrefPanelTerminals_ScreenViewManager alloc] init];
							CFRetainRelease							cancelString(UIStrings_ReturnCopy(kUIStrings_ButtonCancel),
																					CFRetainRelease::kAlreadyRetained);
							CFRetainRelease							okString(UIStrings_ReturnCopy(kUIStrings_ButtonOK),
																				CFRetainRelease::kAlreadyRetained);
							
							
							// display the sheet
							dialog = GenericDialog_Wrap(GenericDialog_NewParentCarbon(TerminalWindow_ReturnWindow(terminalWindow),
																						embeddedPanel, temporaryContext),
														GenericDialog_Wrap::kAlreadyRetained);
							[embeddedPanel release], embeddedPanel = nil; // panel is retained by the call above
							GenericDialog_SetItemTitle(dialog.returnRef(), kGenericDialog_ItemIDButton1, okString.returnCFStringRef());
							GenericDialog_SetItemResponseBlock(dialog.returnRef(), kGenericDialog_ItemIDButton1,
																^{ sheetClosed(dialog.returnRef(), true/* is OK */); });
							GenericDialog_SetItemTitle(dialog.returnRef(), kGenericDialog_ItemIDButton2, cancelString.returnCFStringRef());
							GenericDialog_SetItemResponseBlock(dialog.returnRef(), kGenericDialog_ItemIDButton2,
																^{ sheetClosed(dialog.returnRef(), false/* is OK */); });
							GenericDialog_SetImplementation(dialog.returnRef(), terminalWindow);
							// TEMPORARY; maybe TerminalWindow_Retain/Release concept needs
							// to be implemented and called here; for now, assume that the
							// terminal window will remain valid as long as the dialog exists
							// (that ought to be the case)
							GenericDialog_Display(dialog.returnRef(), true/* animated */, ^{}); // retains dialog until it is dismissed
						}
						
						result = noErr;
					}
					break;
				
				case kCommandTerminalDefault:
					{
						// reformat frontmost window using the Default preferences
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						Preferences_ContextRef			defaultSettings = nullptr;
						
						
						if (kPreferences_ResultOK == Preferences_GetDefaultContext(&defaultSettings, Quills::Prefs::TERMINAL))
						{
							setScreenPreferences(ptr, defaultSettings, true/* animate */);
						}
						
						result = noErr;
					}
					break;
				
				case kCommandTerminalByFavoriteName:
					// IMPORTANT: This implementation is for Carbon compatibility only, as the
					// Session Preferences panel is still Carbon-based and has a menu that
					// relies on this command handler.  The equivalent menu bar command does
					// not use this, it has an associated Objective-C action method.
					{
						// reformat frontmost window using the specified preferences
						if (received.attributes & kHICommandFromMenu)
						{
							My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
							CFStringRef						collectionName = nullptr;
							
							
							if ((noErr == CopyMenuItemTextAsCFString(received.menu.menuRef, received.menu.menuItemIndex, &collectionName)) &&
								Preferences_IsContextNameInUse(Quills::Prefs::TERMINAL, collectionName))
							{
								Preferences_ContextWrap		namedSettings(Preferences_NewContextFromFavorites
																			(Quills::Prefs::TERMINAL, collectionName),
																			Preferences_ContextWrap::kAlreadyRetained);
								
								
								if (namedSettings.exists())
								{
									setScreenPreferences(ptr, namedSettings.returnRef(), true/* animate */);
								}
								CFRelease(collectionName), collectionName = nullptr;
							}
						}
						
						result = noErr;
					}
					break;
				
				case kCommandTranslationTableDefault:
					{
						// change character set of frontmost window according to Default preferences
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						SessionRef						session = SessionFactory_ReturnTerminalWindowSession(terminalWindow);
						
						
						if (nullptr != session)
						{
							Preferences_ContextRef		sessionSettings = Session_ReturnTranslationConfiguration(session);
							
							
							if (nullptr != sessionSettings)
							{
								Preferences_TagSetRef		translationTags = PrefPanelTranslations_NewTagSet();
								
								
								if (nullptr != translationTags)
								{
									Preferences_ContextRef		defaultSettings = nullptr;
									Preferences_Result			prefsResult = Preferences_GetDefaultContext
																				(&defaultSettings, Quills::Prefs::TRANSLATION);
									
									
									if (kPreferences_ResultOK != prefsResult)
									{
										Console_Warning(Console_WriteValue, "failed to locate default translation settings, error", prefsResult);
									}
									else
									{
										prefsResult = Preferences_ContextCopy(defaultSettings, sessionSettings, translationTags);
										if (kPreferences_ResultOK != prefsResult)
										{
											Console_Warning(Console_WriteValue, "failed to apply named translation settings to session, error", prefsResult);
										}
									}
									Preferences_ReleaseTagSet(&translationTags);
								}
							}
						}
						result = noErr;
					}
					break;
				
				case kCommandTranslationTableByFavoriteName:
					// IMPORTANT: This implementation is for Carbon compatibility only, as the
					// Session Preferences panel is still Carbon-based and has a menu that
					// relies on this command handler.  The equivalent menu bar command does
					// not use this, it has an associated Objective-C action method.
					{
						// change character set of frontmost window according to the specified preferences
						if (received.attributes & kHICommandFromMenu)
						{
							My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
							SessionRef						session = SessionFactory_ReturnTerminalWindowSession(terminalWindow);
							CFStringRef						collectionName = nullptr;
							
							
							if ((nullptr != session) &&
								(noErr == CopyMenuItemTextAsCFString(received.menu.menuRef, received.menu.menuItemIndex, &collectionName)) &&
								Preferences_IsContextNameInUse(Quills::Prefs::TRANSLATION, collectionName))
							{
								Preferences_ContextWrap		namedSettings(Preferences_NewContextFromFavorites
																			(Quills::Prefs::TRANSLATION, collectionName),
																			Preferences_ContextWrap::kAlreadyRetained);
								Preferences_ContextRef		sessionSettings = Session_ReturnTranslationConfiguration(session);
								
								
								if (namedSettings.exists() && (nullptr != sessionSettings))
								{
									Preferences_TagSetRef		translationTags = PrefPanelTranslations_NewTagSet();
									
									
									if (nullptr != translationTags)
									{
										// change character set of frontmost window according to the specified preferences
										Preferences_Result		prefsResult = Preferences_ContextCopy
																				(namedSettings.returnRef(), sessionSettings, translationTags);
										
										
										if (kPreferences_ResultOK != prefsResult)
										{
											Console_Warning(Console_WriteLine, "failed to apply named translation settings to session");
										}
										Preferences_ReleaseTagSet(&translationTags);
									}
								}
								CFRelease(collectionName), collectionName = nullptr;
							}
						}
						
						result = noErr;
					}
					break;
				
				case kCommandSetTranslationTable:
					{
						// display a translation customization dialog
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						Preferences_ContextRef			temporaryContext = sheetContextBegin(ptr, Quills::Prefs::TRANSLATION,
																								kMy_SheetTypeTranslation);
						
						
						if (nullptr == temporaryContext)
						{
							Sound_StandardAlert();
							Console_Warning(Console_WriteLine, "failed to construct temporary sheet context");
						}
						else
						{
							GenericDialog_Wrap					dialog;
							PrefPanelTranslations_ViewManager*	embeddedPanel = [[PrefPanelTranslations_ViewManager alloc] init];
							CFRetainRelease						addToPrefsString(UIStrings_ReturnCopy(kUIStrings_PreferencesWindowAddToFavoritesButton),
																					CFRetainRelease::kAlreadyRetained);
							CFRetainRelease						cancelString(UIStrings_ReturnCopy(kUIStrings_ButtonCancel),
																				CFRetainRelease::kAlreadyRetained);
							CFRetainRelease						okString(UIStrings_ReturnCopy(kUIStrings_ButtonOK),
																			CFRetainRelease::kAlreadyRetained);
							
							
							// display the sheet
							dialog = GenericDialog_Wrap(GenericDialog_NewParentCarbon(TerminalWindow_ReturnWindow(terminalWindow),
																						embeddedPanel, temporaryContext),
														GenericDialog_Wrap::kAlreadyRetained);
							[embeddedPanel release], embeddedPanel = nil; // panel is retained by the call above
							GenericDialog_SetItemTitle(dialog.returnRef(), kGenericDialog_ItemIDButton1, okString.returnCFStringRef());
							GenericDialog_SetItemResponseBlock(dialog.returnRef(), kGenericDialog_ItemIDButton1,
																^{ sheetClosed(dialog.returnRef(), true/* is OK */); });
							GenericDialog_SetItemTitle(dialog.returnRef(), kGenericDialog_ItemIDButton2, cancelString.returnCFStringRef());
							GenericDialog_SetItemResponseBlock(dialog.returnRef(), kGenericDialog_ItemIDButton2,
																^{ sheetClosed(dialog.returnRef(), false/* is OK */); });
							GenericDialog_SetItemTitle(dialog.returnRef(), kGenericDialog_ItemIDButton3, addToPrefsString.returnCFStringRef());
							GenericDialog_SetItemResponseBlock(dialog.returnRef(), kGenericDialog_ItemIDButton3,
																^{
																	Preferences_TagSetRef	tagSet = PrefPanelTranslations_NewTagSet();
																	
																	
																	PrefsWindow_AddCollection(temporaryContext, tagSet,
																								kCommandDisplayPrefPanelTranslations);
																	Preferences_ReleaseTagSet(&tagSet);
																});
							GenericDialog_SetImplementation(dialog.returnRef(), terminalWindow);
							// TEMPORARY; maybe TerminalWindow_Retain/Release concept needs
							// to be implemented and called here; for now, assume that the
							// terminal window will remain valid as long as the dialog exists
							// (that ought to be the case)
							GenericDialog_Display(dialog.returnRef(), true/* animated */, ^{}); // retains dialog until it is dismissed
						}
						
						result = noErr;
					}
					break;
				
				case kCommandTerminalNewWorkspace:
					// note that this event often originates from the tab drawer, but
					// due to event hierarchy it will eventually be sent to the handler
					// installed on the parent terminal window (how convenient!)
					SessionFactory_MoveTerminalWindowToNewWorkspace(terminalWindow);
					result = noErr;
					break;
				
				case kCommandToggleTerminalLED1:
					{
						TerminalScreenRef	activeScreen = TerminalWindow_ReturnScreenWithFocus(terminalWindow);
						
						
						if (nullptr == activeScreen)
						{
							// error...
							Sound_StandardAlert();
						}
						else
						{
							Terminal_LEDSetState(activeScreen, 1/* LED number */, false == Terminal_LEDIsOn(activeScreen, 1));
						}
						result = noErr;
					}
					break;
				
				case kCommandToggleTerminalLED2:
					{
						TerminalScreenRef	activeScreen = TerminalWindow_ReturnScreenWithFocus(terminalWindow);
						
						
						if (nullptr == activeScreen)
						{
							// error...
							Sound_StandardAlert();
						}
						else
						{
							Terminal_LEDSetState(activeScreen, 2/* LED number */, false == Terminal_LEDIsOn(activeScreen, 2));
						}
						result = noErr;
					}
					break;
				
				case kCommandToggleTerminalLED3:
					{
						TerminalScreenRef	activeScreen = TerminalWindow_ReturnScreenWithFocus(terminalWindow);
						
						
						if (nullptr == activeScreen)
						{
							// error...
							Sound_StandardAlert();
						}
						else
						{
							Terminal_LEDSetState(activeScreen, 3/* LED number */, false == Terminal_LEDIsOn(activeScreen, 3));
						}
						result = noErr;
					}
					break;
				
				case kCommandToggleTerminalLED4:
					{
						TerminalScreenRef	activeScreen = TerminalWindow_ReturnScreenWithFocus(terminalWindow);
						
						
						if (nullptr == activeScreen)
						{
							// error...
							Sound_StandardAlert();
						}
						else
						{
							Terminal_LEDSetState(activeScreen, 4/* LED number */, false == Terminal_LEDIsOn(activeScreen, 4));
						}
						result = noErr;
					}
					break;
				
				default:
					// ???
					break;
				}
				break;
			
			default:
				// ???
				break;
			}
		}
	}
	return result;
}// receiveHICommand


/*!
Handles "kEventMouseWheelMoved" of "kEventClassMouse".

Invoked by Mac OS X whenever a mouse with a scrolling
function is used on the frontmost window.

(3.1)
*/
OSStatus
receiveMouseWheelEvent	(EventHandlerCallRef	UNUSED_ARGUMENT(inHandlerCallRef),
						 EventRef				inEvent,
						 void*					UNUSED_ARGUMENT(inUserData))
{
	OSStatus		result = eventNotHandledErr;
	UInt32 const	kEventClass = GetEventClass(inEvent);
	UInt32 const	kEventKind = GetEventKind(inEvent);
	
	
	assert(kEventClass == kEventClassMouse);
	assert(kEventKind == kEventMouseWheelMoved);
	{
		EventMouseWheelAxis		axis = kEventMouseWheelAxisY;
		
		
		// find out which way the mouse wheel moved
		result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamMouseWheelAxis, typeMouseWheelAxis, axis);
		
		// if the axis information was found, continue
		if (noErr == result)
		{
			SInt32		delta = 0;
			UInt32		modifiers = 0;
			
			
			// determine modifier keys pressed during scroll
			result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamKeyModifiers, typeUInt32, modifiers);
			if (noErr != result)
			{
				// ignore modifier key parameter if absent
				modifiers = 0;
			}
			
			// determine how far the mouse wheel was scrolled
			// and in which direction; negative means up/left,
			// positive means down/right
			result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamMouseWheelDelta, typeLongInteger, delta);
			
			// if all information can be found, proceed with scrolling
			if (noErr == result)
			{
				HIWindowRef		targetWindow = nullptr;
				
				
				if (noErr != CarbonEventUtilities_GetEventParameter(inEvent, kEventParamWindowRef, typeWindowRef, targetWindow))
				{
					// cannot find information (implies Mac OS X 10.0.x) - fine, assume frontmost window
					targetWindow = EventLoop_ReturnRealFrontWindow();
				}
				
				if (TerminalWindow_ExistsFor(targetWindow))
				{
					TerminalWindowRef		terminalWindow = TerminalWindow_ReturnFromWindow(targetWindow);
					Boolean					isFullScreenWindow = TerminalWindow_IsFullScreen(terminalWindow);
					
					
					if (nullptr == terminalWindow) result = eventNotHandledErr;
					else if (modifiers & controlKey)
					{
						// like Firefox, use control-scroll-wheel to affect font size
						if (false == isFullScreenWindow)
						{
							Commands_ExecuteByIDUsingEvent((delta > 0) ? kCommandBiggerText : kCommandSmallerText);
						}
						result = noErr;
					}
					else if (modifiers & optionKey)
					{
						// adjust screen width or height
						if (kEventMouseWheelAxisX == axis)
						{
							// adjust screen width
							if (false == isFullScreenWindow)
							{
								Commands_ExecuteByIDUsingEvent((delta > 0) ? kCommandNarrowerScreen : kCommandWiderScreen);
							}
							result = noErr;
						}
						else
						{
							if (modifiers & cmdKey)
							{
								// adjust screen width
								if (false == isFullScreenWindow)
								{
									Commands_ExecuteByIDUsingEvent((delta > 0) ? kCommandWiderScreen : kCommandNarrowerScreen);
								}
								result = noErr;
							}
							else
							{
								if (false == isFullScreenWindow)
								{
									Commands_ExecuteByIDUsingEvent((delta > 0) ? kCommandTallerScreen : kCommandShorterScreen);
								}
								result = noErr;
							}
						}
					}
					else
					{
						// ordinary scrolling; when in Full Screen mode, scrolling is allowed
						// as long as the user preference to show a scroll bar is set;
						// otherwise, any form of scrolling (via mouse or not) is disabled
						Boolean		allowScrolling = true;
						
						
						if (TerminalWindow_IsFullScreen(terminalWindow))
						{
							if (kPreferences_ResultOK !=
								Preferences_GetData(kPreferences_TagKioskShowsScrollBar, sizeof(allowScrolling),
													&allowScrolling))
							{
								allowScrolling = true; // assume a value if the preference cannot be found
							}
						}
						
						if (allowScrolling)
						{
							My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
							HIViewRef						scrollBar = ptr->controls.scrollBarV;
							HIViewPartCode					hitPart = (delta > 0)
																		? (modifiers & optionKey)
																			? kControlPageUpPart
																			: kControlUpButtonPart
																		: (modifiers & optionKey)
																			? kControlPageDownPart
																			: kControlDownButtonPart;
							
							
							// vertically scroll the terminal, but 3 lines at a time (scroll wheel)
							InvokeControlActionUPP(scrollBar, hitPart, GetControlAction(scrollBar));
							InvokeControlActionUPP(scrollBar, hitPart, GetControlAction(scrollBar));
							InvokeControlActionUPP(scrollBar, hitPart, GetControlAction(scrollBar));
						}
						result = noErr;
					}
				}
				else
				{
					result = eventNotHandledErr;
				}
			}
		}
	}
	return result;
}// receiveMouseWheelEvent


/*!
Embellishes "kEventControlDraw" of "kEventClassControl"
for scroll bars.

Invoked by Mac OS X whenever a scroll bar needs to be
rendered; calls through to the default renderer, and
then adds “on top” tick marks for any active searches.

(4.0)
*/
OSStatus
receiveScrollBarDraw	(EventHandlerCallRef	inHandlerCallRef,
						 EventRef				inEvent,
						 void*					UNUSED_ARGUMENT(inContext))
{
	UInt32 const	kEventClass = GetEventClass(inEvent);
	UInt32 const	kEventKind = GetEventKind(inEvent);
	assert(kEventClass == kEventClassControl);
	assert(kEventKind == kEventControlDraw);
	OSStatus		result = eventNotHandledErr;
	HIViewRef		view = nullptr;
	
	
	// first use the system implementation to draw the scroll bar,
	// because this drawing should appear “on top”
	UNUSED_RETURN(OSStatus)CallNextEventHandler(inHandlerCallRef, inEvent);
	
	// get the target view
	result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamDirectObject, typeControlRef, view);
	
	// if the view was found, continue
	if (noErr == result)
	{
		TerminalWindowRef	terminalWindow = nullptr;
		OSStatus			error = noErr;
		UInt32				actualSize = 0L;
		CGContextRef		drawingContext = nullptr;
		
		
		// retrieve TerminalWindowRef from the scroll bar
		error = GetControlProperty(view, AppResources_ReturnCreatorCode(),
									kConstantsRegistry_ControlPropertyTypeTerminalWindowRef,
									sizeof(terminalWindow), &actualSize, &terminalWindow);
		assert_noerr(error);
		assert(actualSize == sizeof(terminalWindow));
		
		// determine the context to draw in with Core Graphics
		result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamCGContextRef, typeCGContextRef,
														drawingContext);
		assert_noerr(result);
		
		// if all information can be found, proceed with drawing
		if ((noErr == error) && (noErr == result) && (nullptr != terminalWindow))
		{
			TerminalScreenRef	activeScreen = TerminalWindow_ReturnScreenWithFocus(terminalWindow);
			TerminalViewRef		activeView = TerminalWindow_ReturnViewWithFocus(terminalWindow);
			
			
			// draw line markers
			if (nullptr != activeView)
			{
				HIRect		floatBounds;
				
				
				// determine boundaries of the content view being drawn;
				// ensure view-local coordinates
				HIViewGetBounds(view, &floatBounds);
				
				// overlay tick marks on the region, assuming a vertical scroll bar
				// and using the scale of the underlying terminal screen buffer
				if (TerminalView_SearchResultsExist(activeView))
				{
					TerminalView_CellRangeList	searchResults;
					SInt32						kNumberOfScrollbackLines = Terminal_ReturnInvisibleRowCount(activeScreen);
					SInt32						kNumberOfLines = Terminal_ReturnRowCount(activeScreen) + kNumberOfScrollbackLines;
					TerminalView_Result			viewResult = kTerminalView_ResultOK;
					
					
					viewResult = TerminalView_GetSearchResults(activeView, searchResults);
					if (kTerminalView_ResultOK == viewResult)
					{
						HIRect						trackBounds = floatBounds;
						ThemeScrollBarThumbStyle	arrowLocations = kThemeScrollBarArrowsSingle;
						
						
						// It would be nice to use HITheme APIs here, but after a few trials
						// they seem to be largely broken, returning at best a subset of the
						// required information (e.g. scroll bar boundaries without taking
						// into account the location of arrows).  Therefore, a series of hacks
						// is used instead, to approximate where the arrows will be, in order
						// to avoid drawing on top of any arrows.
						UNUSED_RETURN(OSStatus)GetThemeScrollBarThumbStyle(&arrowLocations);
						trackBounds.size.height -= 2 * kMy_ScrollBarThumbEndCapSize;
						trackBounds.origin.y += kMy_ScrollBarThumbEndCapSize;
						if (kThemeScrollBarArrowsSingle == arrowLocations)
						{
							trackBounds.size.height -= 2 * kMy_ScrollBarArrowHeight;
							trackBounds.origin.y += kMy_ScrollBarArrowHeight;
						}
						else
						{
							// make space for two arrows at each end, regardless
							// (since that is a hidden style that many people use)
							trackBounds.size.height -= 4 * kMy_ScrollBarArrowHeight;
							trackBounds.origin.y += 2 * kMy_ScrollBarArrowHeight;
						}
						
						// now draw the tick marks
						{
							float const				kXPad = 4; // in pixels, arbitrary; reduces line size
							float const				kYPad = 0; // in pixels, arbitrary
							float const				kX1 = trackBounds.origin.x + kXPad;
							float const				kX2 = trackBounds.origin.x + trackBounds.size.width - kXPad - kXPad;
							float const				kY1 = trackBounds.origin.y + kYPad;
							float const				kHeight = trackBounds.size.height - kYPad - kYPad;
							CGContextSaveRestore	_(drawingContext);
							float					y = 0;
							SInt32					topRelativeRow = 0;
							
							
							// arbitrary color
							// TEMPORARY - this could be a preference, even if it is just a low-level setting
							CGContextSetRGBStrokeColor(drawingContext, 1.0/* red */, 0/* green */, 0/* blue */, 1.0/* alpha */);
							
							// draw a line in the scroll bar for each thumb
							// TEMPORARY - this might be very inefficient to calculate per draw;
							// it is probably better to detect changes in the search results,
							// cache the line locations, and then render as often as required
							CGContextBeginPath(drawingContext);
							for (auto cellRange : searchResults)
							{
								// negative means “in scrollback” and positive means “main screen”, so
								// translate into a single space
								topRelativeRow = cellRange.first.second + kNumberOfScrollbackLines;
								
								y = kY1 + topRelativeRow * (kHeight / STATIC_CAST(kNumberOfLines, Float32));
								CGContextMoveToPoint(drawingContext, kX1, y);
								CGContextAddLineToPoint(drawingContext, kX2, y);
							}
							CGContextStrokePath(drawingContext);
						}
					}
				}
			}
		}
	}
	return result;
}// receiveScrollBarDraw


/*!
Handles "kEventControlDragEnter" for a terminal window tab.

Invoked by Mac OS X whenever the tab is involved in a
drag-and-drop operation.

(3.1)
*/
OSStatus
receiveTabDragDrop	(EventHandlerCallRef	UNUSED_ARGUMENT(inHandlerCallRef),
					 EventRef				inEvent,
					 void*					inTerminalWindowRef)
{
@autoreleasepool {
	TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inTerminalWindowRef, TerminalWindowRef);
	UInt32 const		kEventClass = GetEventClass(inEvent);
	UInt32 const		kEventKind = GetEventKind(inEvent);
	OSStatus			result = eventNotHandledErr;
	
	
	assert(kEventClass == kEventClassControl);
	assert(kEventKind == kEventControlDragEnter);
	{
		HIViewRef	view = nullptr;
		
		
		// get the target control
		result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamDirectObject, typeControlRef, view);
		
		// if the control was found, continue
		if (noErr == result)
		{
			DragRef		dragRef = nullptr;
			
			
			// determine the drag taking place
			result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamDragRef, typeDragRef, dragRef);
			if (noErr == result)
			{
				switch (kEventKind)
				{
				case kEventControlDragEnter:
					// indicate whether or not this drag is interesting
					{
						My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
						Boolean							acceptDrag = true;
						
						
						result = SetEventParameter(inEvent, kEventParamControlWouldAcceptDrop,
													typeBoolean, sizeof(acceptDrag), &acceptDrag);
						[ptr->window orderFront:nil];
					}
					break;
				
				default:
					// ???
					result = eventNotHandledErr;
					break;
				}
			}
		}
	}
	return result;
}// @autoreleasepool
}// receiveTabDragDrop


/*!
Handles "kEventToolbarGetAllowedIdentifiers" and
"kEventToolbarGetDefaultIdentifiers" from "kEventClassToolbar"
for the floating general terminal toolbar.  Responds by
updating the given lists of identifiers.

(3.1)
*/
OSStatus
receiveToolbarEvent		(EventHandlerCallRef	UNUSED_ARGUMENT(inHandlerCallRef),
						 EventRef				inEvent,
						 void*					inTerminalWindowRef)
{
	OSStatus			result = eventNotHandledErr;
	TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inTerminalWindowRef, TerminalWindowRef);
	UInt32 const		kEventClass = GetEventClass(inEvent);
	UInt32 const		kEventKind = GetEventKind(inEvent);
	
	
	assert(kEventClass == kEventClassToolbar);
	{
		HIToolbarRef	toolbarRef = nullptr;
		
		
		// determine the command in question
		result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamToolbar, typeHIToolbarRef, toolbarRef);
		
		// if the command information was found, proceed
		if (noErr == result)
		{
			// don’t claim to have handled any commands not shown below
			result = eventNotHandledErr;
			
			switch (kEventKind)
			{
			case kEventToolbarGetAllowedIdentifiers:
				{
					CFMutableArrayRef	allowedIdentifiers = nullptr;
					
					
					result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamMutableArray,
																	typeCFMutableArrayRef, allowedIdentifiers);
					if (noErr == result)
					{
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalLED1);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalLED2);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalLED3);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalLED4);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDScrollLock);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDHideWindow);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDRestartSession);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDFullScreen);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalBell);
						CFArrayAppendValue(allowedIdentifiers, kHIToolbarSpaceIdentifier);
						CFArrayAppendValue(allowedIdentifiers, kHIToolbarFlexibleSpaceIdentifier);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDPrint);
						CFArrayAppendValue(allowedIdentifiers, kConstantsRegistry_HIToolbarItemIDCustomize);
					}
				}
				break;
			
			case kEventToolbarGetDefaultIdentifiers:
				{
					CFMutableArrayRef	defaultIdentifiers = nullptr;
					
					
					result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamMutableArray,
																	typeCFMutableArrayRef, defaultIdentifiers);
					if (noErr == result)
					{
						CFArrayAppendValue(defaultIdentifiers, kHIToolbarSpaceIdentifier);
						CFArrayAppendValue(defaultIdentifiers, kHIToolbarSpaceIdentifier);
						CFArrayAppendValue(defaultIdentifiers, kHIToolbarSpaceIdentifier);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDHideWindow);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDRestartSession);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDScrollLock);
						CFArrayAppendValue(defaultIdentifiers, kHIToolbarFlexibleSpaceIdentifier);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalLED1);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalLED2);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalLED3);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalLED4);
						CFArrayAppendValue(defaultIdentifiers, kHIToolbarFlexibleSpaceIdentifier);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDTerminalBell);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDPrint);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDFullScreen);
						CFArrayAppendValue(defaultIdentifiers, kHIToolbarSpaceIdentifier);
						CFArrayAppendValue(defaultIdentifiers, kHIToolbarSpaceIdentifier);
						CFArrayAppendValue(defaultIdentifiers, kConstantsRegistry_HIToolbarItemIDCustomize);
					}
				}
				break;
			
			case kEventToolbarCreateItemWithIdentifier:
				{
					CFStringRef		identifierCFString = nullptr;
					HIToolbarRef	targetToolbar = nullptr;
					HIToolbarRef	terminalToolbar = nullptr;
					Boolean			isPermanentItem = false;
					
					
					// see if this item is for a toolbar; if not, it may be used for something
					// else (like a customization sheet); this is used to determine whether or
					// not to save the toolbar item reference for later use (e.g. icon updates)
					if (noErr != CarbonEventUtilities_GetEventParameter(inEvent, kEventParamToolbar,
																		typeHIToolbarRef, targetToolbar))
					{
						targetToolbar = nullptr;
					}
					isPermanentItem = (nullptr != targetToolbar);
					if (noErr == GetWindowToolbar(TerminalWindow_ReturnWindow(terminalWindow), &terminalToolbar))
					{
						isPermanentItem = ((isPermanentItem) && (terminalToolbar == targetToolbar));
					}
					
					result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamToolbarItemIdentifier,
																	typeCFStringRef, identifierCFString);
					if (noErr == result)
					{
						CFTypeRef	itemData = nullptr;
						
						
						// NOTE: configuration data is not always present
						result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamToolbarItemConfigData,
																		typeCFTypeRef, itemData);
						if (noErr != result)
						{
							itemData = nullptr;
						}
						
						// create the specified item, if its identifier is recognized
						{
							HIToolbarItemRef	itemRef = nullptr;
							Boolean const		kIs1 = (kCFCompareEqualTo == CFStringCompare
																				(kConstantsRegistry_HIToolbarItemIDTerminalLED1,
																					identifierCFString,
																					kCFCompareBackwards));
							Boolean const		kIs2 = (kCFCompareEqualTo == CFStringCompare
																				(kConstantsRegistry_HIToolbarItemIDTerminalLED2,
																					identifierCFString,
																					kCFCompareBackwards));
							Boolean const		kIs3 = (kCFCompareEqualTo == CFStringCompare
																				(kConstantsRegistry_HIToolbarItemIDTerminalLED3,
																					identifierCFString,
																					kCFCompareBackwards));
							Boolean const		kIs4 = (kCFCompareEqualTo == CFStringCompare
																				(kConstantsRegistry_HIToolbarItemIDTerminalLED4,
																					identifierCFString,
																					kCFCompareBackwards));
							
							
							// all LED items are very similar in appearance, so check all at once
							if ((kIs1) || (kIs2) || (kIs3) || (kIs4))
							{
								My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
								
								
								if (noErr == HIToolbarItemCreate(identifierCFString,
																	kHIToolbarItemNoAttributes, &itemRef))
								{
									CFStringRef		nameCFString = nullptr;
									
									
									// set the label based on which LED is being created
									if (kIs1)
									{
										UInt32 const	kMyCommandID = kCommandToggleTerminalLED1;
										
										
										// then this is the LED 1 item; remember it so it can be updated later
										if (isPermanentItem)
										{
											ptr->toolbarItemLED1.setWithRetain(itemRef);
										}
										
										if (UIStrings_Copy(kUIStrings_ToolbarItemTerminalLED1, nameCFString).ok())
										{
											result = HIToolbarItemSetLabel(itemRef, nameCFString);
											assert_noerr(result);
											result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																				nullptr/* long text */);
											assert_noerr(result);
											result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
											assert_noerr(result);
											CFRelease(nameCFString), nameCFString = nullptr;
										}
									}
									else if (kIs2)
									{
										UInt32 const	kMyCommandID = kCommandToggleTerminalLED2;
										
										
										// then this is the LED 2 item; remember it so it can be updated later
										if (isPermanentItem)
										{
											ptr->toolbarItemLED2.setWithRetain(itemRef);
										}
										
										if (UIStrings_Copy(kUIStrings_ToolbarItemTerminalLED2, nameCFString).ok())
										{
											result = HIToolbarItemSetLabel(itemRef, nameCFString);
											assert_noerr(result);
											result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																				nullptr/* long text */);
											assert_noerr(result);
											result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
											assert_noerr(result);
											CFRelease(nameCFString), nameCFString = nullptr;
										}
									}
									else if (kIs3)
									{
										UInt32 const	kMyCommandID = kCommandToggleTerminalLED3;
										
										
										// then this is the LED 3 item; remember it so it can be updated later
										if (isPermanentItem)
										{
											ptr->toolbarItemLED3.setWithRetain(itemRef);
										}
										
										if (UIStrings_Copy(kUIStrings_ToolbarItemTerminalLED3, nameCFString).ok())
										{
											result = HIToolbarItemSetLabel(itemRef, nameCFString);
											assert_noerr(result);
											result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																				nullptr/* long text */);
											assert_noerr(result);
											result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
											assert_noerr(result);
											CFRelease(nameCFString), nameCFString = nullptr;
										}
									}
									else if (kIs4)
									{
										UInt32 const	kMyCommandID = kCommandToggleTerminalLED4;
										
										
										// then this is the LED 4 item; remember it so it can be updated later
										if (isPermanentItem)
										{
											ptr->toolbarItemLED4.setWithRetain(itemRef);
										}
										
										if (UIStrings_Copy(kUIStrings_ToolbarItemTerminalLED4, nameCFString).ok())
										{
											result = HIToolbarItemSetLabel(itemRef, nameCFString);
											assert_noerr(result);
											result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																				nullptr/* long text */);
											assert_noerr(result);
											result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
											assert_noerr(result);
											CFRelease(nameCFString), nameCFString = nullptr;
										}
									}
									
									// set icon; currently, all LEDs have the same icon, but perhaps
									// some day they will have different colors, etc.
									result = HIToolbarItemSetIconRef(itemRef, gLEDOffIcon());
									assert_noerr(result);
								}
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDScrollLock,
																			identifierCFString, kCFCompareBackwards))
							{
								My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
								
								
								result = HIToolbarItemCreate(identifierCFString,
																kHIToolbarItemNoAttributes, &itemRef);
								if (noErr == result)
								{
									UInt32 const	kMyCommandID = kCommandSuspendNetwork;
									CFStringRef		nameCFString = nullptr;
									
									
									// remember this item so its icon can be kept in sync with scroll lock state
									if (isPermanentItem)
									{
										ptr->toolbarItemScrollLock.setWithRetain(itemRef);
									}
									
									if (Commands_CopyCommandName(kMyCommandID, kCommands_NameTypeShort, nameCFString))
									{
										result = HIToolbarItemSetLabel(itemRef, nameCFString);
										assert_noerr(result);
										result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																			nullptr/* long text */);
										assert_noerr(result);
										CFRelease(nameCFString), nameCFString = nullptr;
									}
									result = HIToolbarItemSetIconRef(itemRef, gScrollLockOnIcon());
									assert_noerr(result);
									result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
									assert_noerr(result);
								}
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDHideWindow,
																			identifierCFString, kCFCompareBackwards))
							{
								My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
								
								
								result = HIToolbarItemCreate(identifierCFString,
																kHIToolbarItemNoAttributes, &itemRef);
								if (noErr == result)
								{
									UInt32 const	kMyCommandID = kCommandHideFrontWindow;
									CFStringRef		nameCFString = nullptr;
									
									
									if (Commands_CopyCommandName(kMyCommandID, kCommands_NameTypeShort, nameCFString))
									{
										result = HIToolbarItemSetLabel(itemRef, nameCFString);
										assert_noerr(result);
										result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																			nullptr/* long text */);
										assert_noerr(result);
										CFRelease(nameCFString), nameCFString = nullptr;
									}
									result = HIToolbarItemSetIconRef(itemRef, gHideWindowIcon());
									assert_noerr(result);
									result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
									assert_noerr(result);
								}
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDFullScreen,
																			identifierCFString, kCFCompareBackwards))
							{
								My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
								
								
								result = HIToolbarItemCreate(identifierCFString,
																kHIToolbarItemNoAttributes, &itemRef);
								if (noErr == result)
								{
									UInt32 const	kMyCommandID = kCommandFullScreenToggle;
									CFStringRef		nameCFString = nullptr;
									
									
									if (Commands_CopyCommandName(kMyCommandID, kCommands_NameTypeShort, nameCFString))
									{
										result = HIToolbarItemSetLabel(itemRef, nameCFString);
										assert_noerr(result);
										result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																			nullptr/* long text */);
										assert_noerr(result);
										CFRelease(nameCFString), nameCFString = nullptr;
									}
									result = HIToolbarItemSetIconRef(itemRef, gFullScreenIcon());
									assert_noerr(result);
									result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
									assert_noerr(result);
								}
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDCustomize,
																			identifierCFString, kCFCompareBackwards))
							{
								My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
								
								
								result = HIToolbarItemCreate(identifierCFString,
																kHIToolbarItemNoAttributes, &itemRef);
								if (noErr == result)
								{
									UInt32 const	kMyCommandID = kHICommandCustomizeToolbar;
									CFStringRef		nameCFString = nullptr;
									
									
									if (Commands_CopyCommandName(kMyCommandID, kCommands_NameTypeShort, nameCFString))
									{
										result = HIToolbarItemSetLabel(itemRef, nameCFString);
										assert_noerr(result);
										result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																			nullptr/* long text */);
										assert_noerr(result);
										CFRelease(nameCFString), nameCFString = nullptr;
									}
									result = HIToolbarItemSetIconRef(itemRef, gCustomizeToolbarIcon());
									assert_noerr(result);
									result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
									assert_noerr(result);
								}
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDPrint,
																			identifierCFString, kCFCompareBackwards))
							{
								My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
								
								
								result = HIToolbarItemCreate(identifierCFString,
																kHIToolbarItemNoAttributes, &itemRef);
								if (noErr == result)
								{
									UInt32 const	kMyCommandID = kCommandPrint;
									CFStringRef		nameCFString = nullptr;
									
									
									if (Commands_CopyCommandName(kMyCommandID, kCommands_NameTypeShort, nameCFString))
									{
										result = HIToolbarItemSetLabel(itemRef, nameCFString);
										assert_noerr(result);
										result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																			nullptr/* long text */);
										assert_noerr(result);
										CFRelease(nameCFString), nameCFString = nullptr;
									}
									result = HIToolbarItemSetIconRef(itemRef, gPrintIcon());
									assert_noerr(result);
									result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
									assert_noerr(result);
								}
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDRestartSession,
																			identifierCFString, kCFCompareBackwards))
							{
								My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
								
								
								result = HIToolbarItemCreate(identifierCFString,
																kHIToolbarItemNoAttributes, &itemRef);
								if (noErr == result)
								{
									UInt32 const	kMyCommandID = kCommandKillProcessesKeepWindow;
									CFStringRef		nameCFString = nullptr;
									
									
									// remember this item so its icon can be kept in sync with the session state
									if (isPermanentItem)
									{
										ptr->toolbarItemKillRestart.setWithRetain(itemRef);
									}
									
									if (Commands_CopyCommandName(kMyCommandID, kCommands_NameTypeShort, nameCFString))
									{
										result = HIToolbarItemSetLabel(itemRef, nameCFString);
										assert_noerr(result);
										result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																			nullptr/* long text */);
										assert_noerr(result);
										CFRelease(nameCFString), nameCFString = nullptr;
									}
									result = HIToolbarItemSetIconRef(itemRef, gKillSessionIcon());
									assert_noerr(result);
									result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
									assert_noerr(result);
								}
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDTerminalBell,
																			identifierCFString, kCFCompareBackwards))
							{
								My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
								
								
								result = HIToolbarItemCreate(identifierCFString,
																kHIToolbarItemNoAttributes, &itemRef);
								if (noErr == result)
								{
									UInt32 const	kMyCommandID = kCommandBellEnabled;
									CFStringRef		nameCFString = nullptr;
									
									
									// then this is the bell item; remember it so it can be updated later
									if (isPermanentItem)
									{
										ptr->toolbarItemBell.setWithRetain(itemRef);
									}
									
									if (Commands_CopyCommandName(kMyCommandID, kCommands_NameTypeShort, nameCFString))
									{
										result = HIToolbarItemSetLabel(itemRef, nameCFString);
										assert_noerr(result);
										result = HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */,
																			nullptr/* long text */);
										assert_noerr(result);
										CFRelease(nameCFString), nameCFString = nullptr;
									}
									result = HIToolbarItemSetIconRef(itemRef, gBellOffIcon());
									assert_noerr(result);
									result = HIToolbarItemSetCommandID(itemRef, kMyCommandID);
									assert_noerr(result);
								}
							}
							
							if (nullptr == itemRef)
							{
								result = eventNotHandledErr;
							}
							else
							{
								result = SetEventParameter(inEvent, kEventParamToolbarItem, typeHIToolbarItemRef,
															sizeof(itemRef), &itemRef);
							}
						}
					}
				}
				break;
			
			case kEventToolbarItemRemoved:
				// if the removed item was a known status item, forget its reference
				{
					HIToolbarItemRef	removedItem = nullptr;
					
					
					result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamToolbarItem,
																	typeHIToolbarItemRef, removedItem);
					if (noErr == result)
					{
						CFStringRef		identifierCFString = nullptr;
						
						
						result = HIToolbarItemCopyIdentifier(removedItem, &identifierCFString);
						if (noErr == result)
						{
							My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
							
							
							// forget any stale references to important items being removed
							if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDScrollLock,
																		identifierCFString, kCFCompareBackwards))
							{
								ptr->toolbarItemScrollLock.clear();
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDTerminalBell,
																		identifierCFString, kCFCompareBackwards))
							{
								ptr->toolbarItemBell.clear();
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDTerminalLED1,
																		identifierCFString, kCFCompareBackwards))
							{
								ptr->toolbarItemLED1.clear();
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDTerminalLED2,
																			identifierCFString, kCFCompareBackwards))
							{
								ptr->toolbarItemLED2.clear();
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDTerminalLED3,
																			identifierCFString, kCFCompareBackwards))
							{
								ptr->toolbarItemLED3.clear();
							}
							else if (kCFCompareEqualTo == CFStringCompare(kConstantsRegistry_HIToolbarItemIDTerminalLED4,
																			identifierCFString, kCFCompareBackwards))
							{
								ptr->toolbarItemLED4.clear();
							}
							
							CFRelease(identifierCFString), identifierCFString = nullptr;
						}
					}
				}
				break;
			
			default:
				// ???
				break;
			}
		}
	}
	
	return result;
}// receiveToolbarEvent


/*!
Handles "kEventWindowCursorChange" of "kEventClassWindow",
or "kEventRawKeyModifiersChanged" of "kEventClassKeyboard",
for a terminal window.

(3.1)
*/
OSStatus
receiveWindowCursorChange	(EventHandlerCallRef	UNUSED_ARGUMENT(inHandlerCallRef),
							 EventRef				inEvent,
							 void*					UNUSED_ARGUMENT(inTerminalWindowRef))
{
	OSStatus		result = eventNotHandledErr;
	UInt32 const	kEventClass = GetEventClass(inEvent);
	UInt32 const	kEventKind = GetEventKind(inEvent);
	
	
	assert(((kEventClass == kEventClassWindow) && (kEventKind == kEventWindowCursorChange)) ||
			((kEventClass == kEventClassKeyboard) && (kEventKind == kEventRawKeyModifiersChanged)));
	
	// do not change the cursor if this window is not active
	if (kEventClass == kEventClassWindow)
	{
		HIWindowRef		window = nullptr;
		
		
		// determine the window in question
		result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamDirectObject, typeWindowRef, window);
		if (noErr == result)
		{
			Point	globalMouse;
			
			
			result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamMouseLocation, typeQDPoint, globalMouse);
			if (noErr == result)
			{
				UInt32		modifiers = 0;
				
				
				// try to vary the cursor according to key modifiers, but it’s no
				// catastrophe if this information isn’t available
				if (noErr != CarbonEventUtilities_GetEventParameter(inEvent, kEventParamKeyModifiers, typeUInt32, modifiers))
				{
					modifiers = EventLoop_ReturnCurrentModifiers();
				}
				
				// finally, set the cursor
				result = setCursorInWindow(window, globalMouse, modifiers);
			}
		}
	}
	else
	{
		// when the key modifiers change, it is still nice to have the
		// cursor automatically change when necessary; however, there
		// is no mouse information available, so it must be determined
		UInt32		modifiers = 0;
		Point		globalMouse;
		
		
		UNUSED_RETURN(OSStatus)CarbonEventUtilities_GetEventParameter(inEvent, kEventParamKeyModifiers, typeUInt32, modifiers);
		GetMouse(&globalMouse);
		result = setCursorInWindow(GetUserFocusWindow(), globalMouse, modifiers);
	}
	
	return result;
}// receiveWindowCursorChange


/*!
Handles "kEventWindowDragCompleted" of "kEventClassWindow"
for a terminal window.

(3.1)
*/
OSStatus
receiveWindowDragCompleted	(EventHandlerCallRef	UNUSED_ARGUMENT(inHandlerCallRef),
							 EventRef				inEvent,
							 void*					inTerminalWindowRef)
{
	OSStatus			result = eventNotHandledErr;
	TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inTerminalWindowRef, TerminalWindowRef);
	UInt32 const		kEventClass = GetEventClass(inEvent);
	UInt32 const		kEventKind = GetEventKind(inEvent);
	
	
	assert(kEventClass == kEventClassWindow);
	assert(kEventKind == kEventWindowDragCompleted);
	{
		WindowRef	window = nullptr;
		
		
		// determine the window in question
		result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamDirectObject, typeWindowRef, window);
		
		// if the window was found, proceed
		if (result == noErr)
		{
			My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
			
			
			// check the tab location and fix if necessary
			if (ptr->tab.exists())
			{
				HIWindowRef		tabWindow = REINTERPRET_CAST(ptr->tab.returnHIObjectRef(), HIWindowRef);
				
				
				if (GetDrawerPreferredEdge(tabWindow) != GetDrawerCurrentEdge(tabWindow))
				{
					OSStatus	error = noErr;
					
					
					// toggle twice; the first should close the drawer at its
					// “wrong” location, the 2nd should open it on the right edge
					error = CloseDrawer(tabWindow, false/* asynchronously */);
					if (noErr == error)
					{
						error = OpenDrawer(tabWindow, kWindowEdgeDefault, true/* asynchronously */);
						if (noErr != error)
						{
							Console_Warning(Console_WriteValue, "failed to open drawer during drag to terminal window, error", error);
						}
					}
				}
			}
		}
	}
	
	return result;
}// receiveWindowDragCompleted


/*!
Handles "kEventWindowFullScreenEnterStarted", "kEventWindowFullScreenEnterCompleted",
"kEventWindowFullScreenExitStarted" and "kEventWindowFullScreenExitCompleted" of
"kEventClassWindow" for a terminal window.

(4.1)
*/
OSStatus
receiveWindowFullScreenChange	(EventHandlerCallRef	UNUSED_ARGUMENT(inHandlerCallRef),
								 EventRef				inEvent,
								 void*					inTerminalWindowRef)
{
	UInt32 const		kEventClass = GetEventClass(inEvent);
	UInt32 const		kEventKind = GetEventKind(inEvent);
	UInt32 const		enterStarted = FUTURE_SYMBOL(241, kEventWindowFullScreenEnterStarted);
	UInt32 const		enterCompleted = FUTURE_SYMBOL(242, kEventWindowFullScreenEnterCompleted);
	UInt32 const		exitStarted = FUTURE_SYMBOL(243, kEventWindowFullScreenExitStarted);
	UInt32 const		exitCompletedOrFailed = FUTURE_SYMBOL(244, kEventWindowFullScreenExitCompleted);
	UInt32				keyModifiers = 0;
	HIWindowRef			window = nullptr;
	TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inTerminalWindowRef, TerminalWindowRef);
	OSStatus			result = eventNotHandledErr;
	
	
	assert(kEventClass == kEventClassWindow);
	assert((kEventKind == enterStarted) ||
			(kEventKind == enterCompleted) ||
			(kEventKind == exitStarted) ||
			(kEventKind == exitCompletedOrFailed));
	
	// determine which special keys are down
	if (noErr != CarbonEventUtilities_GetEventParameter(inEvent, kEventParamKeyModifiers, typeUInt32, keyModifiers))
	{
		// hack...
		if (EventLoop_IsOptionKeyDown())
		{
			keyModifiers |= optionKey;
		}
	}
	
	// all event types have a window as a direct object
	result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamDirectObject, typeWindowRef, window);
	if (noErr == result)
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
		Boolean const					kSwapModes = (0 != (keyModifiers & optionKey)); // MUST be consistent with other modifier-key checks for this flag
		
		
		switch (kEventKind)
		{
		case enterStarted:
			setUpForFullScreenModal(ptr, true, kSwapModes, kMy_FullScreenStateInProgress);
			break;
		
		case enterCompleted:
			setUpForFullScreenModal(ptr, true, kSwapModes, kMy_FullScreenStateCompleted);
			break;
		
		case exitStarted:
			setUpForFullScreenModal(ptr, false, kSwapModes, kMy_FullScreenStateInProgress);
			break;
		
		case exitCompletedOrFailed:
			setUpForFullScreenModal(ptr, false, kSwapModes, kMy_FullScreenStateCompleted);
			break;
		
		default:
			// ???
			result = eventNotHandledErr;
			break;
		}
	}
	
	return result;
}// receiveWindowFullScreenChange


/*!
Embellishes "kEventWindowResizeStarted", "kEventWindowBoundsChanging",
and "kEventWindowResizeCompleted" of "kEventClassWindow" for a
terminal window.

(3.0)
*/
OSStatus
receiveWindowResize		(EventHandlerCallRef	UNUSED_ARGUMENT(inHandlerCallRef),
						 EventRef				inEvent,
						 void*					inTerminalWindowRef)
{
@autoreleasepool {
	TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inTerminalWindowRef, TerminalWindowRef);
	UInt32 const		kEventClass = GetEventClass(inEvent);
	UInt32 const		kEventKind = GetEventKind(inEvent);
	OSStatus			result = eventNotHandledErr;
	
	
	assert(kEventClass == kEventClassWindow);
	assert((kEventKind == kEventWindowResizeStarted) ||
			(kEventKind == kEventWindowBoundsChanging) ||
			(kEventKind == kEventWindowResizeCompleted));
	{
		WindowRef	window = nullptr;
		
		
		// determine the window in question
		result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamDirectObject, typeWindowRef, window);
		
		// if the window was found, proceed
		if (result == noErr)
		{
			Boolean							useSheet = false;
			My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
			
			
			if (kEventKind == kEventWindowResizeStarted)
			{
				TerminalViewRef		focusedView = TerminalWindow_ReturnViewWithFocus(terminalWindow);
				
				
				// on Mac OS X 10.7 and beyond, the system can initiate resizes in ways that do
				// not allow the detection of modifier keys; so unfortunately it is necessary
				// to check the raw key state at this point (e.g. responding to clicks in a
				// size box will no longer work)
				if (nullptr != focusedView)
				{
					// remember the previous view mode, so that it can be restored later
					ptr->preResizeViewDisplayMode = TerminalView_ReturnDisplayMode(focusedView);
					
					// the Control key must be used because Mac OS X 10.7 assigns special
					// meaning to the Shift and Option keys during a window resize
					if (EventLoop_IsControlKeyDown())
					{
						TerminalView_SetDisplayMode(focusedView,
													(kTerminalView_DisplayModeNormal ==
														TerminalView_ReturnDisplayMode(focusedView))
														? kTerminalView_DisplayModeZoom
														: kTerminalView_DisplayModeNormal);
					}
				}
				
				// display resize info in a floating window
				[[[TerminalWindow_ResizeInfoController sharedTerminalWindowResizeInfoController] window] center];
				[[TerminalWindow_ResizeInfoController sharedTerminalWindowResizeInfoController] showWindow:NSApp];
				
				// remember the old window title
				{
					CFStringRef		nameCFString = BRIDGE_CAST([ptr->window title], CFStringRef);
					
					
					ptr->preResizeTitleString.setWithRetain(nameCFString);
				}
			}
			else if ((kEventKind == kEventWindowBoundsChanging) && (ptr->preResizeTitleString.exists()))
			{
				// for bounds-changing, ensure a resize is in progress (denoted
				// by a non-nullptr preserved title string), make sure the window
				// bounds are changing because of a user interaction, and make
				// sure the dimensions themselves are changing
				UInt32		attributes = 0L;
				
				
				result = CarbonEventUtilities_GetEventParameter(inEvent, kEventParamAttributes, typeUInt32, attributes);
				if ((result == noErr) && (attributes & kWindowBoundsChangeUserResize) &&
					(attributes & kWindowBoundsChangeSizeChanged))
				{
					// update display; the contents of the display depend on the view mode,
					// either dimension changing (the default) or font size changing
					CFStringRef			newTitle = nullptr;
					TerminalViewRef		focusedView = TerminalWindow_ReturnViewWithFocus(terminalWindow);
					Boolean				isFontSizeDisplay = false;
					
					
					if (nullptr != focusedView)
					{
						isFontSizeDisplay = (kTerminalView_DisplayModeZoom == TerminalView_ReturnDisplayMode(focusedView));
					}
					
					if (isFontSizeDisplay)
					{
						// font size display
						UInt16		fontSize = 0;
						
						
						TerminalWindow_GetFontAndSize(terminalWindow, nullptr/* font */, &fontSize);
						newTitle = CFStringCreateWithFormat(kCFAllocatorDefault, nullptr/* options */,
															CFSTR("%d pt")/* LOCALIZE THIS */, fontSize);
					}
					else
					{
						// columns and rows display
						UInt16		columns = 0;
						UInt16		rows = 0;
						
						
						TerminalWindow_GetScreenDimensions(terminalWindow, &columns, &rows);
						newTitle = CFStringCreateWithFormat(kCFAllocatorDefault, nullptr/* options */,
															CFSTR("%dx%d")/* LOCALIZE THIS */, columns, rows);
					}
					
					if (nullptr != newTitle)
					{
						unless (useSheet)
						{
							// here the title is set directly, instead of via the
							// TerminalWindow_SetWindowTitle() routine, because
							// it is a “secret” and temporary change to the title
							// that will be undone when resizing completes
							[ptr->window setTitle:BRIDGE_CAST(newTitle, NSString*)];
						}
						
						// update the floater
						[TerminalWindow_ResizeInfoController sharedTerminalWindowResizeInfoController].resizeInfoText = BRIDGE_CAST(newTitle, NSString*);
						
						CFRelease(newTitle), newTitle = nullptr;
					}
				}
			}
			else if (kEventKind == kEventWindowResizeCompleted)
			{
				// in case the reverse resize mode was enabled by the resize click, restore the original resize mode
				{
					TerminalViewRef		focusedView = TerminalWindow_ReturnViewWithFocus(terminalWindow);
					
					
					if (nullptr != focusedView)
					{
						TerminalView_SetDisplayMode(focusedView, ptr->preResizeViewDisplayMode);
					}
				}
				
				// dispose of the floater
				[[TerminalWindow_ResizeInfoController sharedTerminalWindowResizeInfoController] close];
				
				// restore the window title
				if (ptr->preResizeTitleString.exists())
				{
					[ptr->window setTitle:(NSString*)ptr->preResizeTitleString.returnCFStringRef()];
					ptr->preResizeTitleString.clear();
				}
			}
		}
	}
	
	return result;
}// @autoreleasepool
}// receiveWindowResize


/*!
Implementation of TerminalWindow_ReturnWindow().

(4.0)
*/
HIWindowRef
returnCarbonWindow		(My_TerminalWindowPtr	inPtr)
{
@autoreleasepool {
	HIWindowRef		result = nullptr;
	
	
	result = (HIWindowRef)[inPtr->window windowRef];
	return result;
}// @autoreleasepool
}// returnCarbonWindow


/*!
Returns the height in pixels of the grow box in a terminal
window.  Currently this is identical to the height of a
horizontal scroll bar, but this function exists so that
code can explicitly identify this metric when no horizontal
scroll bar may be present or when the size box is missing
(Full Screen mode).

(3.0)
*/
UInt16
returnGrowBoxHeight		(My_TerminalWindowPtr	inPtr)
{
	UInt16				result = 0;
	Boolean				hasSizeBox = false;
	WindowAttributes	attributes = kWindowNoAttributes;
	OSStatus			error = noErr;
	
	
	error = GetWindowAttributes(returnCarbonWindow(inPtr), &attributes);
	if (noErr != error)
	{
		// not sure if the window has a size box; assume it does
		hasSizeBox = true;
	}
	else
	{
		if (attributes & kWindowResizableAttribute)
		{
			hasSizeBox = true;
		}
	}
	
	if (hasSizeBox)
	{
		SInt32		data = 0;
		
		
		error = GetThemeMetric(kThemeMetricScrollBarWidth, &data);
		if (noErr != error)
		{
			Console_WriteValue("unexpected error using GetThemeMetric()", error);
			result = 16; // arbitrary
		}
		else
		{
			result = STATIC_CAST(data, UInt16);
		}
	}
	return result;
}// returnGrowBoxHeight


/*!
Returns the width in pixels of the grow box in a terminal
window.  Currently this is identical to the width of a
vertical scroll bar, but this function exists so that code
can explicitly identify this metric when no vertical scroll
bar may be present.

(3.0)
*/
UInt16
returnGrowBoxWidth		(My_TerminalWindowPtr	inPtr)
{
	return returnScrollBarWidth(inPtr);
}// returnGrowBoxWidth


/*!
Returns the height in pixels of a scroll bar in the given
terminal window.  If the scroll bar is invisible, the height
is set to 0.

(3.0)
*/
UInt16
returnScrollBarHeight	(My_TerminalWindowPtr	UNUSED_ARGUMENT(inPtr))
{
	UInt16		result = 0;
	//SInt32		data = 0L;
	//OSStatus	error = noErr;
	
	
	// temporarily disable horizontal scroll bars; one option
	// is to have this routine dynamically return a nonzero
	// height if the terminal actually needs horizontal
	// scrolling (extremely rare), and to otherwise use 0 to
	// effectively hide the scroll bar and save some space
#if 0
	error = GetThemeMetric(kThemeMetricScrollBarWidth, &data);
	if (error != noErr) Console_WriteValue("unexpected error using GetThemeMetric()", error);
	result = data;
#endif
	return result;
}// returnScrollBarHeight


/*!
Returns the width in pixels of a scroll bar in the given
terminal window.  If the scroll bar is invisible, the width
is set to 0.

(3.0)
*/
UInt16
returnScrollBarWidth	(My_TerminalWindowPtr	inPtr)
{
	UInt16		result = 0;
	Boolean		showScrollBar = true;
	
	
	if (kPreferences_ResultOK !=
		Preferences_GetData(kPreferences_TagKioskShowsScrollBar, sizeof(showScrollBar),
							&showScrollBar))
	{
		showScrollBar = true; // assume a value if the preference cannot be found
	}
	
	if ((false == TerminalWindow_IsFullScreen(inPtr->selfRef)) || (showScrollBar))
	{
		SInt32		data = 0L;
		OSStatus	error = noErr;
		
		
		error = GetThemeMetric(kThemeMetricScrollBarWidth, &data);
		if (error != noErr) Console_WriteValue("unexpected error using GetThemeMetric()", error);
		result = STATIC_CAST(data, UInt16);
	}
	return result;
}// returnScrollBarWidth


/*!
Returns the height in pixels of the status bar.  The status bar
height is defined as the number of pixels between the toolbar
and the top edge of the terminal screen; thus, an invisible
status bar has zero height.

(3.0)
*/
UInt16
returnStatusBarHeight	(My_TerminalWindowPtr	UNUSED_ARGUMENT(inPtr))
{
	return 0;
}// returnStatusBarHeight


/*!
Returns the height in pixels of the toolbar.  The toolbar
height is defined as the number of pixels between the top
edge of the window and the top edge of the status bar; thus,
an invisible toolbar has zero height.

(3.0)
*/
UInt16
returnToolbarHeight		(My_TerminalWindowPtr	UNUSED_ARGUMENT(inPtr))
{
	return 0;
}// returnToolbarHeight


/*!
Returns a display ID for the specified window.

(4.1)
*/
CGDirectDisplayID
returnWindowDisplay		(HIWindowRef	inWindow)
{
	CGDirectDisplayID	result = kCGNullDirectDisplay;
	
	
	UNUSED_RETURN(Boolean)RegionUtilities_GetWindowDirectDisplayID(inWindow, result);
	
	return result;
}// returnWindowDisplay


/*!
This routine, of standard UndoActionProcPtr form,
can undo or redo changes to the font and/or font
size of a terminal screen.

Note that it will really be nice to get all of
the AppleScript stuff working, so junk like this
does not have to be done using Copy-and-Paste
coding™, and can be made into a recordable event.

(3.0)
*/
void
reverseFontChanges	(Undoables_ActionInstruction	inDoWhat,
					 Undoables_ActionRef			inApplicableAction,
					 void*							inContextPtr)
{
	// this routine only recognizes one kind of context - be absolutely sure that’s what was given!
	assert(Undoables_ReturnActionID(inApplicableAction) == kUndoableContextIdentifierTerminalFontSizeChanges);
	
	{
		UndoDataFontSizeChangesPtr	dataPtr = REINTERPRET_CAST(inContextPtr, UndoDataFontSizeChangesPtr);
		
		
		switch (inDoWhat)
		{
		case kUndoables_ActionInstructionDispose:
			// release memory previously allocated when this action was installed
			Undoables_DisposeAction(&inApplicableAction);
			if (nullptr != dataPtr)
			{
				delete dataPtr, dataPtr = nullptr;
			}
			break;
		
		case kUndoables_ActionInstructionRedo:
		case kUndoables_ActionInstructionUndo:
		default:
			{
				UInt16			oldFontSize = 0;
				CFStringRef		oldFontName = nullptr;
				
				
				// make this reversible by preserving the font information
				TerminalWindow_GetFontAndSize(dataPtr->terminalWindow, &oldFontName, &oldFontSize);
				
				// change the font and/or size of the window
				TerminalWindow_SetFontAndSize(dataPtr->terminalWindow,
												(dataPtr->undoFont) ? dataPtr->fontName.returnCFStringRef() : nullptr,
												(dataPtr->undoFontSize) ? dataPtr->fontSize : 0);
				
				// save the font and size
				dataPtr->fontSize = oldFontSize;
				dataPtr->fontName.setWithRetain(oldFontName);
			}
			break;
		}
	}
}// reverseFontChanges


/*!
This routine, of standard UndoActionProcPtr form,
can undo or redo changes to the dimensions of a
terminal screen.

(3.1)
*/
void
reverseScreenDimensionChanges	(Undoables_ActionInstruction	inDoWhat,
								 Undoables_ActionRef			inApplicableAction,
								 void*							inContextPtr)
{
	// this routine only recognizes one kind of context - be absolutely sure that’s what was given!
	assert(Undoables_ReturnActionID(inApplicableAction) == kUndoableContextIdentifierTerminalDimensionChanges);
	
	{
		UndoDataScreenDimensionChangesPtr	dataPtr = REINTERPRET_CAST(inContextPtr, UndoDataScreenDimensionChangesPtr);
		
		
		switch (inDoWhat)
		{
		case kUndoables_ActionInstructionDispose:
			// release memory previously allocated when this action was installed
			Undoables_DisposeAction(&inApplicableAction);
			if (nullptr != dataPtr)
			{
				delete dataPtr, dataPtr = nullptr;
			}
			break;
		
		case kUndoables_ActionInstructionRedo:
		case kUndoables_ActionInstructionUndo:
		default:
			{
				UInt16		oldColumns = 0;
				UInt16		oldRows = 0;
				
				
				// make this reversible by preserving the dimensions
				TerminalWindow_GetScreenDimensions(dataPtr->terminalWindow, &oldColumns, &oldRows);
				
				// resize the window
				TerminalWindow_SetScreenDimensions(dataPtr->terminalWindow, dataPtr->columns, dataPtr->rows,
													true/* recordable */);
				
				// save the dimensions
				dataPtr->columns = oldColumns;
				dataPtr->rows = oldRows;
			}
			break;
		}
	}
}// reverseScreenDimensionChanges


/*!
This is a standard control action procedure that dynamically
scrolls a terminal window.

(2.6)
*/
void
scrollProc	(HIViewRef			inScrollBarClicked,
			 HIViewPartCode		inPartCode)
{
	TerminalWindowRef	terminalWindow = nullptr;
	OSStatus			error = noErr;
	UInt32				actualSize = 0L;
	
	
	// retrieve TerminalWindowRef from control
	error = GetControlProperty(inScrollBarClicked, AppResources_ReturnCreatorCode(),
								kConstantsRegistry_ControlPropertyTypeTerminalWindowRef,
								sizeof(terminalWindow), &actualSize, &terminalWindow);
	assert_noerr(error);
	assert(actualSize == sizeof(terminalWindow));
	
	if (nullptr != terminalWindow)
	{
		My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
		TerminalViewRef					view = nullptr;
		My_ScrollBarKind				kind = kMy_InvalidScrollBarKind;
		
		
		view = getScrollBarView(ptr, inScrollBarClicked); // 3.0
		kind = getScrollBarKind(ptr, inScrollBarClicked); // 3.0
		
		if (kMy_ScrollBarKindHorizontal == kind)
		{
			switch (inPartCode)
			{
			case kControlUpButtonPart: // “up arrow” on a horizontal scroll bar means “left arrow”
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollColumnsTowardRightEdge(view, 1/* number of columns to scroll */);
				break;
			
			case kControlDownButtonPart: // “down arrow” on a horizontal scroll bar means “right arrow”
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollColumnsTowardLeftEdge(view, 1/* number of columns to scroll */);
				break;
			
			case kControlPageUpPart:
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollPageTowardRightEdge(view);
				break;
			
			case kControlPageDownPart:
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollPageTowardLeftEdge(view);
				break;
			
			case kControlIndicatorPart:
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollToIndicatorPosition(view, GetControl32BitValue(ptr->controls.scrollBarV),
																							GetControl32BitValue(ptr->controls.scrollBarH));
				break;
			
			default:
				// ???
				break;
			}
		}
		else if (kMy_ScrollBarKindVertical == kind)
		{
			switch (inPartCode)
			{
			case kControlUpButtonPart:
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollRowsTowardBottomEdge(view, 1/* number of rows to scroll */);
				break;
			
			case kControlDownButtonPart:
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollRowsTowardTopEdge(view, 1/* number of rows to scroll */);
				break;
			
			case kControlPageUpPart:
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollPageTowardBottomEdge(view);
				break;
			
			case kControlPageDownPart:
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollPageTowardTopEdge(view);
				break;
			
			case kControlIndicatorPart:
				UNUSED_RETURN(TerminalView_Result)TerminalView_ScrollToIndicatorPosition(view, GetControl32BitValue(ptr->controls.scrollBarV));
				break;
			
			default:
				// ???
				break;
			}
		}
	}
}// scrollProc


/*!
Invoked whenever a monitored session state is changed
(see TerminalWindow_New() to see which states are
monitored).  This routine responds by updating session
windows appropriately.

(3.0)
*/
void
sessionStateChanged		(ListenerModel_Ref		UNUSED_ARGUMENT(inUnusedModel),
						 ListenerModel_Event	inSessionSettingThatChanged,
						 void*					inEventContextPtr,
						 void*					inTerminalWindowRef)
{
@autoreleasepool {
	TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inTerminalWindowRef, TerminalWindowRef);
	
	
	switch (inSessionSettingThatChanged)
	{
	case kSession_ChangeSelected:
		// bring the window to the front, unhiding it if necessary
		{
			SessionRef		session = REINTERPRET_CAST(inEventContextPtr, SessionRef);
			
			
			// this handler is invoked for changes to ANY session,
			// but the response is specific to one, so check first
			if (Session_ReturnActiveTerminalWindow(session) == terminalWindow)
			{
				My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
				
				
				TerminalWindow_SetObscured(terminalWindow, false);
				[ptr->window makeKeyAndOrderFront:nil];
			}
		}
		break;
	
	case kSession_ChangeState:
		// update various GUI elements to reflect the new session state
		{
			SessionRef						session = REINTERPRET_CAST(inEventContextPtr, SessionRef);
			My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
			
			
			// this handler is invoked for changes to ANY session,
			// but the response is specific to one, so check first
			if (Session_ReturnActiveTerminalWindow(session) == terminalWindow)
			{
				// set the initial window title
				if (Session_StateIsActiveUnstable(session))
				{
					CFStringRef		titleCFString = nullptr;
					
					
					if (kSession_ResultOK == Session_GetWindowUserDefinedTitle(session, titleCFString))
					{
						TerminalWindow_SetWindowTitle(terminalWindow, titleCFString);
					}
					
					// the restart toolbar item, if visible, should have its icon and command set
					if (ptr->toolbarItemKillRestart.exists())
					{
						UInt32 const		kNewCommandID = kCommandKillProcessesKeepWindow;
						HIToolbarItemRef	itemRef = ptr->toolbarItemKillRestart.returnHIObjectRef();
						CFStringRef			nameCFString = nullptr;
						OSStatus			error = noErr;
						
						
						if (Commands_CopyCommandName(kNewCommandID, kCommands_NameTypeShort, nameCFString))
						{
							error = HIToolbarItemSetLabel(itemRef, nameCFString);
							assert_noerr(error);
							UNUSED_RETURN(OSStatus)HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */, nullptr/* long text */);
							CFRelease(nameCFString), nameCFString = nullptr;
						}
						error = HIToolbarItemSetIconRef(itemRef, gKillSessionIcon());
						assert_noerr(error);
						error = HIToolbarItemSetCommandID(itemRef, kNewCommandID);
						assert_noerr(error);
					}
				}
				if (Session_StateIsActiveUnstable(session) || Session_StateIsActiveStable(session))
				{
					// the cursor should be allowed to render once again, if it was inhibited
					for (auto viewRef : ptr->allViews)
					{
						UNUSED_RETURN(TerminalView_Result)TerminalView_SetCursorRenderingEnabled(viewRef, true);
					}
				}
				// add or remove window adornments as appropriate; once a session has died
				// its window (if left open by the user) won’t display a warning, so the
				// adornment is removed in that case, although its title is then changed
				if (Session_StateIsActiveStable(session)) setWarningOnWindowClose(ptr, true);
				if (Session_StateIsDead(session))
				{
					ptr->isDead = true;
					TerminalWindow_SetWindowTitle(terminalWindow, nullptr/* keep title, evaluate state again */);
					setWarningOnWindowClose(ptr, false);
					
					// the restart toolbar item, if visible, should have its icon and command changed
					if (ptr->toolbarItemKillRestart.exists())
					{
						UInt32 const		kNewCommandID = kCommandRestartSession;
						HIToolbarItemRef	itemRef = ptr->toolbarItemKillRestart.returnHIObjectRef();
						CFStringRef			nameCFString = nullptr;
						OSStatus			error = noErr;
						
						
						if (Commands_CopyCommandName(kNewCommandID, kCommands_NameTypeShort, nameCFString))
						{
							error = HIToolbarItemSetLabel(itemRef, nameCFString);
							assert_noerr(error);
							UNUSED_RETURN(OSStatus)HIToolbarItemSetHelpText(itemRef, nameCFString/* short text */, nullptr/* long text */);
							CFRelease(nameCFString), nameCFString = nullptr;
						}
						error = HIToolbarItemSetIconRef(itemRef, gRestartSessionIcon());
						assert_noerr(error);
						error = HIToolbarItemSetCommandID(itemRef, kNewCommandID);
						assert_noerr(error);
					}
					
					// the cursor should not be displayed for inactive sessions
					for (auto viewRef : ptr->allViews)
					{
						UNUSED_RETURN(TerminalView_Result)TerminalView_SetCursorRenderingEnabled(viewRef, false);
					}
				}
				else
				{
					ptr->isDead = false;
				}
			}
		}
		break;
	
	case kSession_ChangeStateAttributes:
		// update various GUI elements to reflect the new session state
		{
			SessionRef		session = REINTERPRET_CAST(inEventContextPtr, SessionRef);
			
			
			// this handler is invoked for changes to ANY session,
			// but the response is specific to one, so check first
			if (Session_ReturnActiveTerminalWindow(session) == terminalWindow)
			{
				CFStringRef		titleCFString = nullptr;
				
				
				if (kSession_ResultOK == Session_GetWindowUserDefinedTitle(session, titleCFString))
				{
					TerminalWindow_SetWindowTitle(terminalWindow, titleCFString);
				}
			}
		}
		break;
	
	case kSession_ChangeWindowInvalid:
		// if a window is still Full Screen, kick it into normal mode
		{
			SessionRef		session = REINTERPRET_CAST(inEventContextPtr, SessionRef);
			
			
			// this handler is invoked for changes to ANY session,
			// but the response is specific to one, so check first
			if (Session_ReturnActiveTerminalWindow(session) == terminalWindow)
			{
				if (TerminalWindow_IsFullScreen(terminalWindow))
				{
					My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
					
					
					setTerminalWindowFullScreen(ptr, false/* full screen */, false/* swap view mode */);
				}
			}
		}
		break;
	
	case kSession_ChangeWindowTitle:
		// update the window based on the new session title
		{
			SessionRef		session = REINTERPRET_CAST(inEventContextPtr, SessionRef);
			
			
			// this handler is invoked for changes to ANY session,
			// but the response is specific to one, so check first
			if (Session_ReturnActiveTerminalWindow(session) == terminalWindow)
			{
				CFStringRef		titleCFString = nullptr;
				
				
				if (kSession_ResultOK == Session_GetWindowUserDefinedTitle(session, titleCFString))
				{
					TerminalWindow_SetWindowTitle(terminalWindow, titleCFString);
				}
			}
		}
		break;
	
	default:
		// ???
		break;
	}
}// @autoreleasepool
}// sessionStateChanged


/*!
Adds or removes a Full Screen icon from the specified window.
Not for normal use, called as a side effect of changes to
user preferences.

(4.1)
*/
void
setCarbonWindowFullScreenIcon	(HIWindowRef	inWindow,
								 Boolean		inHasFullScreenIcon)
{
	int		windowBits[] = { FUTURE_SYMBOL(45, kHIWindowBitFullScreenPrimary), 0 }; // must be zero-terminated
	int		noBits[] = { 0 }; // must be zero-terminated
	
	
	if (inHasFullScreenIcon)
	{
		assert_noerr(HIWindowChangeAttributes(inWindow, windowBits/* bits to set */, noBits/* bits to clear */));
	}
	else
	{
		assert_noerr(HIWindowChangeAttributes(inWindow, noBits/* bits to set */, windowBits/* bits to clear */));
	}
}// setCarbonWindowFullScreenIcon


/*!
Adds or removes a Full Screen icon from the specified window.
Not for normal use, called as a side effect of changes to
user preferences.

(4.1)
*/
void
setCocoaWindowFullScreenIcon	(NSWindow*	inWindow,
								 Boolean	inHasFullScreenIcon)
{
	if (inHasFullScreenIcon)
	{
		[inWindow setCollectionBehavior:([inWindow collectionBehavior] | FUTURE_SYMBOL(1 << 7, NSWindowCollectionBehaviorFullScreenPrimary))];
	}
	else
	{
		[inWindow setCollectionBehavior:([inWindow collectionBehavior] & ~(FUTURE_SYMBOL(1 << 7, NSWindowCollectionBehaviorFullScreenPrimary)))];
	}
}// setCocoaWindowFullScreenIcon


/*!
Based on the specified global mouse location and
event modifiers, sets the cursor appropriately
for the given window.

(3.1)
*/
OSStatus
setCursorInWindow	(HIWindowRef	inWindow,
					 Point			inGlobalMouse,
					 UInt32			inModifiers)
{
	OSStatus	result = noErr;
	HIViewRef	contentView = nullptr;
	
	
	// find content view (needed to translate coordinates)
	result = HIViewFindByID(HIViewGetRoot(inWindow), kHIViewWindowContentID, &contentView);
	if (noErr == result)
	{
		CGrafPtr	oldPort = nullptr;
		GDHandle	oldDevice = nullptr;
		Point		localMouse;
		HIPoint		localMouseHIPoint;
		HIViewRef	viewUnderMouse = nullptr;
		
		
		GetGWorld(&oldPort, &oldDevice);
		SetPortWindowPort(inWindow);
		localMouse = inGlobalMouse;
		GlobalToLocal(&localMouse);
		localMouseHIPoint = CGPointMake(localMouse.h, localMouse.v);
		
		// figure out what view is under the specified point
		result = HIViewGetSubviewHit(contentView, &localMouseHIPoint, true/* deepest */, &viewUnderMouse);
		if ((noErr != result) || (nullptr == viewUnderMouse))
		{
			// nothing underneath the mouse, or some problem; restore the arrow and claim all is well
			[[NSCursor arrowCursor] set];
			result = noErr;
		}
		else
		{
			ControlKind		controlKind;
			Boolean			wasSet = false;
			
			
			result = GetControlKind(viewUnderMouse, &controlKind);
			if ((noErr == result) &&
				(AppResources_ReturnCreatorCode() == controlKind.signature) &&
				(kConstantsRegistry_ControlKindTerminalView == controlKind.kind))
			{
				// set the cursor appropriately in whatever control is under the mouse
				result = HandleControlSetCursor(viewUnderMouse, localMouse, STATIC_CAST(inModifiers, EventModifiers), &wasSet);
				if (noErr != result)
				{
					// some problem; restore the arrow and claim all is well
					[[NSCursor arrowCursor] set];
					result = noErr;
				}						
			}
			else
			{
				// unknown control type - restore arrow
				[[NSCursor arrowCursor] set];
				result = noErr;
			}
		}
		SetGWorld(oldPort, oldDevice);
	}
	
	return result;
}// setCursorInWindow


/*!
Copies the screen size and scrollback settings from the given
context to the underlying terminal buffer.  The main view is
updated to the size that will show the new dimensions entirely
at the current font size.  The window size changes to fit the
new screen.

See also TerminalWindow_SetScreenDimensions().

(4.0)
*/
void
setScreenPreferences	(My_TerminalWindowPtr		inPtr,
						 Preferences_ContextRef		inContext,
						 Boolean					inAnimateWindowChanges)
{
	TerminalScreenRef		activeScreen = getActiveScreen(inPtr);
	
	
	if (nullptr != activeScreen)
	{
		Preferences_TagSetRef	tagSet = PrefPanelTerminals_NewScreenPaneTagSet();
		Preferences_Result		prefsResult = kPreferences_ResultOK;
		
		
		prefsResult = Preferences_ContextCopy(inContext, Terminal_ReturnConfiguration(activeScreen), tagSet);
		if (kPreferences_ResultOK != prefsResult)
		{
			Console_Warning(Console_WriteValue, "failed to overwrite terminal screen configuration, error", prefsResult);
		}
		
		Preferences_ReleaseTagSet(&tagSet);
		
		// IMPORTANT: this window adjustment should match TerminalWindow_SetScreenDimensions()
		unless (inPtr->viewSizeIndependent)
		{
			UInt16		columns = 0;
			UInt16		rows = 0;
			
			
			prefsResult = Preferences_ContextGetData(inContext, kPreferences_TagTerminalScreenColumns,
														sizeof(columns), &columns, true/* search defaults */);
			if (kPreferences_ResultOK == prefsResult)
			{
				prefsResult = Preferences_ContextGetData(inContext, kPreferences_TagTerminalScreenRows,
															sizeof(rows), &rows, true/* search defaults */);
				if (kPreferences_ResultOK == prefsResult)
				{
					Terminal_SetVisibleScreenDimensions(activeScreen, columns, rows);
					setWindowToIdealSizeForDimensions(inPtr, columns, rows, inAnimateWindowChanges);
				}
			}
		}
	}
}// setScreenPreferences


/*!
Sets the standard state (for zooming) of the given
terminal window to match the size required to fit
the specified width and height in pixels.

Once this is done, you can make the window this
size by zooming “out”, or by passing "true" for
"inResizeWindow".

(3.0)
*/
void
setStandardState	(My_TerminalWindowPtr	inPtr,
					 UInt16					inScreenWidthInPixels,
					 UInt16					inScreenHeightInPixels,
					 Boolean				inResizeWindow,
					 Boolean				inAnimatedResize)
{
	SInt16		windowWidth = 0;
	SInt16		windowHeight = 0;
	
	
	getWindowSizeFromViewSize(inPtr, inScreenWidthInPixels, inScreenHeightInPixels, &windowWidth, &windowHeight);
	UNUSED_RETURN(OSStatus)inPtr->windowResizeHandler.setWindowIdealSize(windowWidth, windowHeight);
	{
		Rect		structureBounds;
		Rect		contentBounds;
		OSStatus	error = noErr;
		
		
		error = GetWindowBounds(returnCarbonWindow(inPtr), kWindowStructureRgn, &structureBounds);
		assert_noerr(error);
		error = GetWindowBounds(returnCarbonWindow(inPtr), kWindowContentRgn, &contentBounds);
		assert_noerr(error);
		
		// force the current size regardless (in reality, the event handlers
		// will be consulted so that the window size is constrained); but
		// resize at the same time, if that is applicable
		if (inResizeWindow)
		{
			SInt16 const	kExtraWidth = ((structureBounds.right - structureBounds.left) -
											(contentBounds.right - contentBounds.left));
			SInt16 const	kExtraHeight = ((structureBounds.bottom - structureBounds.top) -
											(contentBounds.bottom - contentBounds.top));
			
			
			structureBounds.right = structureBounds.left + windowWidth + kExtraWidth;
			structureBounds.bottom = structureBounds.top + windowHeight + kExtraHeight;
		}
		if (inAnimatedResize)
		{
			error = TransitionWindow(returnCarbonWindow(inPtr), kWindowSlideTransitionEffect,
										kWindowResizeTransitionAction, &structureBounds);
			assert_noerr(error);
		}
		else
		{
			error = SetWindowBounds(returnCarbonWindow(inPtr), kWindowStructureRgn, &structureBounds);
			assert_noerr(error);
		}
	}
}// setStandardState


/*!
Specifies whether or not the given terminal window takes over
its entire display.  This is also used to zoom a window to its
largest possible size without entering a modal state.

If "inIsModal" is not set, “full screen” is simply a request
to zoom the window to fit the screen as well as possible (or
return it to its original size) without changing system-wide
state such as the Dock and menu bar.

Otherwise, the window is zoomed to fill the screen and it
enters a special mode (e.g. the menu bar may be hidden and
various commands may become unavailable).  The exact behavior
depends on the user preference for using the full-screen mode
of the OS:

- If the new full-screen mode (introduced in Lion) is used,
  the window zooms to Full Screen with animation and the menu
  bar is hidden but remains accessible.  User preferences to
  disable Force Quit, show the title bar or permanently hide
  the menu bar are ignored because the system does not
  support them in this mode.

- If the original full-screen mode is in effect, the window
  zooms to Full Screen without animation and the user has
  more control over what is disabled (e.g. many more menu
  commands can be inactive and the entire window frame can
  remain visible if desired).  On the other hand, the mode
  is more permanent: it does not allow any number of other
  windows to also become Full Screen as their own Spaces.

(4.1)
*/
void
setTerminalWindowFullScreen		(My_TerminalWindowPtr	inPtr,
								 Boolean				inIsFullScreen,
								 Boolean				inSwapViewMode)
{
	Boolean		useCustomFullScreenMode = false; // if not set, implies modal mode
	
	
	if (false == inIsFullScreen)
	{
		// if the window is already Full Screen, it must be returned
		// in the way that it started (the user may have changed the
		// preference in the meantime)
		useCustomFullScreenMode = (false == inPtr->fullScreen.isUsingOS);
	}
	else
	{
		if (kPreferences_ResultOK !=
			Preferences_GetData(kPreferences_TagKioskNoSystemFullScreenMode, sizeof(useCustomFullScreenMode),
								&useCustomFullScreenMode))
		{
			useCustomFullScreenMode = false; // assume a value if the preference cannot be found
		}
	}
	
	// enable kiosk mode only if it is not enabled already
	if (inIsFullScreen)
	{
		if (useCustomFullScreenMode)
		{
			// old-style Full Screen
			Rect		maxBounds;
			Boolean		showWindowFrame = true;
			
			
			// prepare to enter full-screen mode
			setUpForFullScreenModal(inPtr, true, inSwapViewMode, kMy_FullScreenStateInProgress);
			
			// read relevant user preferences
			if (kPreferences_ResultOK !=
				Preferences_GetData(kPreferences_TagKioskShowsWindowFrame, sizeof(showWindowFrame),
									&showWindowFrame))
			{
				showWindowFrame = true; // assume a value if the preference cannot be found
			}
			
			if (showWindowFrame)
			{
				RegionUtilities_GetWindowMaximumBounds(returnCarbonWindow(inPtr), &maxBounds,
														nullptr/* previous bounds */, true/* no insets */);
			}
			else
			{
				// entire screen is available, so use it
				RegionUtilities_GetWindowDeviceGrayRect(returnCarbonWindow(inPtr), &maxBounds);
			}
			
			UNUSED_RETURN(OSStatus)SetWindowBounds(returnCarbonWindow(inPtr), kWindowContentRgn, &maxBounds);
			
			// finish initiation of full-screen mode
			setUpForFullScreenModal(inPtr, true, inSwapViewMode, kMy_FullScreenStateCompleted);
		}
		else
		{
			// new-style Full Screen (take over display); first select the
			// target window to make sure the command is handled properly
			// (NOTE: Carbon event handlers respond to key transitions,
			// effectively performing the same calls as the old-style
			// version above)
			TerminalWindow_Select(inPtr->selfRef);
			Commands_ExecuteByIDUsingEvent(FUTURE_SYMBOL('fsm ', kHICommandToggleFullScreen));
		}
	}
	else
	{
		if (useCustomFullScreenMode)
		{
			// prepare to return to normal mode
			setUpForFullScreenModal(inPtr, false, inSwapViewMode, kMy_FullScreenStateInProgress);
			
			// old-style Full Screen; restore window frame
			UNUSED_RETURN(OSStatus)SetWindowBounds(returnCarbonWindow(inPtr), kWindowContentRgn, &inPtr->fullScreen.oldContentBounds);
			
			// finish return to normal mode
			setUpForFullScreenModal(inPtr, false, inSwapViewMode, kMy_FullScreenStateCompleted);
		}
		else
		{
			// new-style Full Screen (take over display); first select the
			// target window to make sure the command is handled properly
			// (NOTE: Carbon event handlers respond to key transitions,
			// effectively performing the same calls as the old-style
			// version above)
			TerminalWindow_Select(inPtr->selfRef);
			Commands_ExecuteByIDUsingEvent(FUTURE_SYMBOL('fsm ', kHICommandToggleFullScreen),
											GetWindowEventTarget(returnCarbonWindow(inPtr)));
		}
	}
}// setTerminalWindowFullScreen


/*!
This routine handles any side effects that should occur when a
window is entering or exiting full-screen mode.

Currently this handles things like hiding or showing the scroll
bar when the user preference for “no scroll bar” is set.

This must be a separate function from any code that makes a
window actually enter or exit full-screen (such as when handling
a command) because the system-provided Full Screen mode can be
triggered indirectly.

(4.1)
*/
void
setUpForFullScreenModal		(My_TerminalWindowPtr	inPtr,
							 Boolean				inWillBeFullScreen,
							 Boolean				inSwapViewMode,
							 My_FullScreenState		inState)
{
	SystemUIOptions		optionsForFullScreen = 0;
	Boolean				useCustomFullScreenMode = true;
	Boolean				showOffSwitch = true;
	Boolean				showScrollBar = true;
	Boolean				allowForceQuit = true;
	Boolean				showMenuBar = true;
	Boolean				showWindowFrame = true;
	
	
	if (false == inWillBeFullScreen)
	{
		// if the window is already Full Screen, it must be returned
		// in the way that it started (the user may have changed the
		// preference in the meantime)
		useCustomFullScreenMode = (false == inPtr->fullScreen.isUsingOS);
	}
	else
	{
		if (kPreferences_ResultOK !=
			Preferences_GetData(kPreferences_TagKioskNoSystemFullScreenMode, sizeof(useCustomFullScreenMode),
								&useCustomFullScreenMode))
		{
			useCustomFullScreenMode = false; // assume a value if the preference cannot be found
		}
	}
	
	if (kPreferences_ResultOK !=
		Preferences_GetData(kPreferences_TagKioskShowsOffSwitch, sizeof(showOffSwitch),
							&showOffSwitch))
	{
		showOffSwitch = true; // assume a value if the preference cannot be found
	}
	
	if (kPreferences_ResultOK !=
		Preferences_GetData(kPreferences_TagKioskShowsScrollBar, sizeof(showScrollBar),
							&showScrollBar))
	{
		showScrollBar = true; // assume a value if the preference cannot be found
	}
	
	if (kPreferences_ResultOK !=
		Preferences_GetData(kPreferences_TagKioskAllowsForceQuit, sizeof(allowForceQuit),
							&allowForceQuit))
	{
		allowForceQuit = true; // assume a value if the preference cannot be found
	}
	unless (allowForceQuit) optionsForFullScreen |= kUIOptionDisableForceQuit;
	
	if (kPreferences_ResultOK !=
		Preferences_GetData(kPreferences_TagKioskShowsMenuBar, sizeof(showMenuBar),
							&showMenuBar))
	{
		showMenuBar = false; // assume a value if the preference cannot be found
	}
	if (showMenuBar) optionsForFullScreen |= kUIOptionAutoShowMenuBar;
	
	if (kPreferences_ResultOK !=
		Preferences_GetData(kPreferences_TagKioskShowsWindowFrame, sizeof(showWindowFrame),
							&showWindowFrame))
	{
		showWindowFrame = true; // assume a value if the preference cannot be found
	}
	
	// if the system’s own Full Screen method is in use, fix
	// certain settings (they have no effect anyway)
	if (false == useCustomFullScreenMode)
	{
		allowForceQuit = true;
		showMenuBar = true;
		showWindowFrame = false;
	}
	
	if (inWillBeFullScreen)
	{
		// prepare to turn on Full Screen; “completed” means “everything
		// that happens AFTER the window frame is made full-screen”, whereas
		// the pre-completed setup all happens BEFORE the frame is changed;
		// everything here should be the opposite of the off-state code below
		if (kMy_FullScreenStateCompleted == inState)
		{
			// hide or disable the close box, zoom box and size box
			UNUSED_RETURN(OSStatus)ChangeWindowAttributes(returnCarbonWindow(inPtr), 0/* attributes to set */,
															kWindowCollapseBoxAttribute | kWindowFullZoomAttribute |
															kWindowResizableAttribute/* attributes to clear */);
			
			if (useCustomFullScreenMode)
			{
				// remove any shadow so that “neighboring” full-screen windows
				// on other displays do not appear to have shadows over them
				[inPtr->window setHasShadow:NO];
			}
			
			// show “off switch” if user has requested it
			if (showOffSwitch)
			{
				Keypads_SetVisible(kKeypads_WindowTypeFullScreen, true);
				SelectWindow(returnCarbonWindow(inPtr)); // return focus to the terminal window
				CocoaBasic_MakeFrontWindowCarbonUserFocusWindow();
			}
			
			// set flags last because the window is not in a complete
			// full-screen state until every change is in effect
			inPtr->fullScreen.isOn = true;
			inPtr->fullScreen.isUsingOS = (false == useCustomFullScreenMode);
		}
		else
		{
			TerminalView_DisplayMode const	kOldMode = TerminalView_ReturnDisplayMode(inPtr->allViews.front());
			
			
			// initialize the structure to a known state
			bzero(&inPtr->fullScreen, sizeof(inPtr->fullScreen));
			
			if (useCustomFullScreenMode)
			{
				if (false == TerminalWindow_IsFullScreenMode())
				{
					// no windows are full-screen yet so turn on the system-wide
					// mode (hiding the menu bar and Dock, etc.); do this early
					// so that the usable screen space is up-to-date when the
					// window tries to figure out how much space it can use
					assert_noerr(SetSystemUIMode(kUIModeAllHidden, optionsForFullScreen));
				}
			}
			
			unless (showScrollBar)
			{
				UNUSED_RETURN(OSStatus)HIViewSetVisible(inPtr->controls.scrollBarV, false);
			}
			
			// configure the view to allow a font size change instead of
			// a dimension change, when appropriate; also store enough
			// information to reverse all changes later (IMPORTANT: this
			// changes the user’s preferred behavior for the window and
			// it must be undone when Full Screen ends)
			TerminalWindow_GetFontAndSize(inPtr->selfRef, nullptr/* font name */, &inPtr->fullScreen.oldFontSize);
			UNUSED_RETURN(OSStatus)GetWindowBounds(returnCarbonWindow(inPtr), kWindowContentRgn, &inPtr->fullScreen.oldContentBounds);
			inPtr->fullScreen.oldMode = kOldMode;
			inPtr->fullScreen.newMode = (false == inSwapViewMode)
										? kOldMode
										: (kTerminalView_DisplayModeZoom == kOldMode)
											? kTerminalView_DisplayModeNormal
											: kTerminalView_DisplayModeZoom;
			if (inPtr->fullScreen.newMode != inPtr->fullScreen.oldMode)
			{
				TerminalView_SetDisplayMode(inPtr->allViews.front(), inPtr->fullScreen.newMode);
				setViewSizeIndependentFromWindow(inPtr, true);
			}
		}
	}
	else
	{
		// prepare to turn off Full Screen; “completed” means “everything
		// that happens AFTER the window frame is changed back”, whereas
		// the pre-completed setup all happens BEFORE the frame is changed;
		// everything here should be the opposite of the code above
		if (kMy_FullScreenStateCompleted == inState)
		{
			// restore the close box, zoom box and size box
			UNUSED_RETURN(OSStatus)ChangeWindowAttributes(returnCarbonWindow(inPtr),
															kWindowCollapseBoxAttribute | kWindowFullZoomAttribute |
															kWindowResizableAttribute/* attributes to set */,
															0/* attributes to clear */);
			
			// the scroll bar may or may not have been hidden but
			// just show it anyway; that way, if preferences were
			// crossed or some other condition changed, the
			// window cannot end up with a missing scroll bar
			UNUSED_RETURN(OSStatus)HIViewSetVisible(inPtr->controls.scrollBarV, true);
			
			if (inPtr->fullScreen.newMode != inPtr->fullScreen.oldMode)
			{
				// window is set to normally zoom text but was temporarily
				// changing dimensions; wait until now (after frame has
				// been restored) to reverse the display mode setting so
				// that the text zoom is not affected by the frame change
				if (kTerminalView_DisplayModeZoom == inPtr->fullScreen.oldMode)
				{
					TerminalView_SetDisplayMode(inPtr->allViews.front(), inPtr->fullScreen.oldMode);
					setViewSizeIndependentFromWindow(inPtr, false);
				}
			}
		}
		else
		{
			// clear flags immediately because the window is not in a
			// complete full-screen state once it has started to change back
			inPtr->fullScreen.isOn = false;
			inPtr->fullScreen.isUsingOS = false;
			
			if (useCustomFullScreenMode)
			{
				if (false == TerminalWindow_IsFullScreenMode())
				{
					// no windows remain that are full-screen; turn off the
					// system-wide mode (restoring the menu bar and Dock, etc.)
					assert_noerr(SetSystemUIMode(kUIModeNormal, 0/* options */));
				}
			}
			
			// restore the shadow
			[inPtr->window setHasShadow:YES];
			
			// now explicitly disable settings that apply to Full Screen
			// mode as a whole (and not to each window)
			Keypads_SetVisible(kKeypads_WindowTypeFullScreen, false);
			
			if (inPtr->fullScreen.newMode != inPtr->fullScreen.oldMode)
			{
				// window is set to normally change dimensions but was temporarily
				// zooming its font; reverse the display mode setting and font
				// before the frame changes back so that a normal window resize
				// will automatically set the correct original dimensions
				if (kTerminalView_DisplayModeNormal == inPtr->fullScreen.oldMode)
				{
					// normal mode (window size reflects screen dimensions)
					TerminalView_SetDisplayMode(inPtr->allViews.front(), inPtr->fullScreen.oldMode);
					TerminalWindow_SetFontAndSize(inPtr->selfRef, nullptr/* font name */, inPtr->fullScreen.oldFontSize);
					setViewSizeIndependentFromWindow(inPtr, false);
				}
			}
		}
	}
}// setUpForFullScreenModal


/*!
Copies the format settings (like font and colors) from the given
context to every view in the window.  The window size changes to
fit any new font.

See also TerminalWindow_SetFontAndSize().

(4.0)
*/
void
setViewFormatPreferences	(My_TerminalWindowPtr		inPtr,
							 Preferences_ContextRef		inContext)
{
	if (false == inPtr->allViews.empty())
	{
		TerminalViewRef				activeView = getActiveView(inPtr);
		TerminalView_DisplayMode	oldMode = kTerminalView_DisplayModeNormal;
		TerminalView_Result			viewResult = kTerminalView_ResultOK;
		Preferences_TagSetRef		tagSet = PrefPanelFormats_NewTagSet();
		Preferences_Result			prefsResult = kPreferences_ResultOK;
		
		
		// TEMPORARY; should iterate over other views if there is ever more than one
		oldMode = TerminalView_ReturnDisplayMode(activeView);
		viewResult = TerminalView_SetDisplayMode(activeView, kTerminalView_DisplayModeNormal);
		assert(kTerminalView_ResultOK == viewResult);
		prefsResult = Preferences_ContextCopy(inContext, TerminalView_ReturnFormatConfiguration(activeView), tagSet);
		if (kPreferences_ResultOK != prefsResult)
		{
			Console_Warning(Console_WriteValue, "failed to copy terminal screen Format configuration, error", prefsResult);
		}
		viewResult = TerminalView_SetDisplayMode(activeView, oldMode);
		assert(kTerminalView_ResultOK == viewResult);
		
		Preferences_ReleaseTagSet(&tagSet);
		
		// IMPORTANT: this window adjustment should match TerminalWindow_SetFontAndSize()
		unless (inPtr->viewSizeIndependent)
		{
			setWindowToIdealSizeForFont(inPtr);
		}
	}
}// setViewFormatPreferences


/*!
This internal state changes in certain special situations
(such as during the transition to full-screen mode) to
temporarily prevent view dimension or font size changes
from triggering “ideal” window resizes to match those
changes.  Normally, the flag should be true.

This is useful for full-screen mode because the window
should be flush to an exact size (that of the display),
whereas in most cases it is better to make the window no
bigger than it needs to be.

(4.0)
*/
void
setViewSizeIndependentFromWindow	(My_TerminalWindowPtr	inPtr,
									 Boolean				inWindowResizesWhenViewSizeChanges)
{
	inPtr->viewSizeIndependent = inWindowResizesWhenViewSizeChanges;
}// setViewSizeIndependentFromWindow


/*!
Copies the translation settings (like the character set) from
the given context to every view in the window.

WARNING:	This is done internally to propagate settings to all
			the right places beneath a window, but this is not a
			good entry point for changing translation settings!
			Copy changes into a Session-level configuration, as
			returned by Session_ReturnTranslationConfiguration(),
			so that the Session is always aware of them.

(4.0)
*/
void
setViewTranslationPreferences	(My_TerminalWindowPtr		inPtr,
								 Preferences_ContextRef		inContext)
{
	if (false == inPtr->allViews.empty())
	{
		TerminalViewRef				activeView = getActiveView(inPtr);
		Preferences_TagSetRef		tagSet = PrefPanelTranslations_NewTagSet();
		Preferences_Result			prefsResult = kPreferences_ResultOK;
		
		
		// TEMPORARY; should iterate over other views if there is ever more than one
		prefsResult = Preferences_ContextCopy(inContext, TerminalView_ReturnTranslationConfiguration(activeView), tagSet);
		if (kPreferences_ResultOK != prefsResult)
		{
			Console_Warning(Console_WriteValue, "failed to copy terminal screen Translation configuration, error", prefsResult);
		}
		
		Preferences_ReleaseTagSet(&tagSet);
	}
}// setViewTranslationPreferences


/*!
Adorns or strips a window frame indicator showing
that a warning message will appear if the user
tries to close the window.  On Mac OS 8/9, this
disables any window proxy icon; on Mac OS X, a dot
also appears in the close box.

NOTE:	This does NOT force a warning message to
		appear, this call is nothing more than an
		adornment.  Making the window’s behavior
		consistent with the adornment is up to you.

(3.0)
*/
void
setWarningOnWindowClose		(My_TerminalWindowPtr	inPtr,
							 Boolean				inCloseBoxHasDot)
{
	if (nil != inPtr->window)
	{
		// attach or remove an adornment in the window that shows
		// that attempting to close it will display a warning;
		// on Mac OS X, a dot appears in the middle of the close box
		UNUSED_RETURN(OSStatus)SetWindowModified(returnCarbonWindow(inPtr), inCloseBoxHasDot);
	}
}// setWarningOnWindowClose


/*!
Changes the title of the terminal window, and any tab
associated with it, to the specified string.

See also TerminalWindow_SetWindowTitle().

(4.0)
*/
void
setWindowAndTabTitle	(My_TerminalWindowPtr	inPtr,
						 CFStringRef			inNewTitle)
{
@autoreleasepool {
	[inPtr->window setTitle:(NSString*)inNewTitle];
	if (inPtr->tab.exists())
	{
		HIViewWrap			titleWrap(idMyLabelTabTitle,
										REINTERPRET_CAST(inPtr->tab.returnHIObjectRef(), HIWindowRef));
		HMHelpContentRec	helpTag;
		
		
		// set text
		SetControlTextWithCFString(titleWrap, inNewTitle);
		
		// set help tag, to show full title on hover
		// in case it is too long to display
		bzero(&helpTag, sizeof(helpTag));
		helpTag.version = kMacHelpVersion;
		helpTag.tagSide = kHMOutsideBottomCenterAligned;
		helpTag.content[0].contentType = kHMCFStringContent;
		helpTag.content[0].u.tagCFString = inNewTitle;
		helpTag.content[1].contentType = kHMCFStringContent;
		helpTag.content[1].u.tagCFString = CFSTR("");
		OSStatus error = noErr;
		//(OSStatus)HMSetControlHelpContent(titleWrap, &helpTag);
		error = HMSetControlHelpContent(titleWrap, &helpTag);
		assert_noerr(error);
	}
}// @autoreleasepool
}// setWindowAndTabTitle


/*!
Resizes the window so that its main view is large enough for
the specified number of columns and rows at the current font
size.  Split-pane views are removed.

(4.0)
*/
void
setWindowToIdealSizeForDimensions	(My_TerminalWindowPtr	inPtr,
									 UInt16					inColumns,
									 UInt16					inRows,
									 Boolean				inAnimateWindowChanges)
{
	if (false == inPtr->allViews.empty())
	{
		TerminalViewRef				activeView = getActiveView(inPtr);
		TerminalView_PixelWidth		screenWidth;
		TerminalView_PixelHeight	screenHeight;
		
		
		TerminalView_GetTheoreticalViewSize(activeView/* TEMPORARY - must consider a list of views */,
											inColumns, inRows, screenWidth, screenHeight);
		setStandardState(inPtr, screenWidth.integralPixels(), screenHeight.integralPixels(), true/* resize window */, inAnimateWindowChanges);
	}
}// setWindowToIdealSizeForDimensions


/*!
Resizes the window so that its main view is large enough to
render the current number of columns and rows using the font
and font size of the view.

(4.0)
*/
void
setWindowToIdealSizeForFont		(My_TerminalWindowPtr	inPtr)
{
	if (false == inPtr->allViews.empty())
	{
		TerminalViewRef				activeView = getActiveView(inPtr);
		TerminalView_PixelWidth		screenWidth;
		TerminalView_PixelHeight	screenHeight;
		
		
		TerminalView_GetIdealSize(activeView/* TEMPORARY - must consider a list of views */,
									screenWidth, screenHeight);
		setStandardState(inPtr, screenWidth.integralPixels(), screenHeight.integralPixels(), true/* resize window */);
	}
}// setWindowToIdealSizeForFont


/*!
Responds to a close of any sheet on a Terminal Window that
is updating a context constructed by sheetContextBegin().

This calls sheetContextEnd() to ensure that the context is
cleaned up.

(4.0)
*/
void
sheetClosed		(GenericDialog_Ref		inDialogThatClosed,
				 Boolean				inOKButtonPressed)
{
	TerminalWindowRef				ref = REINTERPRET_CAST(GenericDialog_ReturnImplementation(inDialogThatClosed), TerminalWindowRef);
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), ref);
	
	
	if (nullptr == ptr)
	{
		Console_Warning(Console_WriteLine, "unexpected problem finding Terminal Window that corresponds to a closed sheet");
	}
	else
	{
		if (inOKButtonPressed)
		{
			switch (ptr->sheetType)
			{
			case kMy_SheetTypeFormat:
				setViewFormatPreferences(ptr, ptr->recentSheetContext.returnRef());
				break;
			
			case kMy_SheetTypeScreenSize:
				installUndoScreenDimensionChanges(ref);
				setScreenPreferences(ptr, ptr->recentSheetContext.returnRef());
				break;
			
			case kMy_SheetTypeTranslation:
				setViewTranslationPreferences(ptr, ptr->recentSheetContext.returnRef());
				break;
			
			default:
				Console_Warning(Console_WriteLine, "no active sheet but sheet context still exists and was changed");
				break;
			}
		}
		
		sheetContextEnd(ptr);
	}
}// sheetClosed


/*!
Constructs a new sheet context and starts monitoring it for
changes.  The given sheet type determines what the response
will be when settings are dumped into the target context.

The returned context is stored as "recentSheetContext" in the
specified window structure, and is nullptr if there was any
error.

(4.0)
*/
Preferences_ContextRef
sheetContextBegin	(My_TerminalWindowPtr	inPtr,
					 Quills::Prefs::Class	inClass,
					 My_SheetType			inSheetType)
{
	Preferences_ContextWrap		newContext(Preferences_NewContext(inClass),
											Preferences_ContextWrap::kAlreadyRetained);
	Preferences_ContextRef		result = nullptr;
	
	
	if (kMy_SheetTypeNone == inPtr->sheetType)
	{
		Preferences_Result		prefsResult = kPreferences_ResultOK;
		Boolean					copyOK = false;
		
		
		// initialize settings so that the sheet has the right data
		// IMPORTANT: the contexts and tag sets chosen here should match those
		// used elsewhere in this file to update preferences later (that is,
		// in setScreenPreferences(), setViewFormatPreferences() and
		// setViewTranslationPreferences())
		switch (inSheetType)
		{
		case kMy_SheetTypeFormat:
			{
				Preferences_TagSetRef	tagSet = PrefPanelFormats_NewTagSet();
				
				
				prefsResult = Preferences_ContextCopy(TerminalView_ReturnFormatConfiguration(getActiveView(inPtr)),
														newContext.returnRef(), tagSet);
				if (kPreferences_ResultOK == prefsResult)
				{
					copyOK = true;
				}
				Preferences_ReleaseTagSet(&tagSet);
			}
			break;
		
		case kMy_SheetTypeScreenSize:
			{
				Preferences_TagSetRef	tagSet = PrefPanelTerminals_NewScreenPaneTagSet();
				
				
				prefsResult = Preferences_ContextCopy(Terminal_ReturnConfiguration(getActiveScreen(inPtr)),
														newContext.returnRef(), tagSet);
				if (kPreferences_ResultOK == prefsResult)
				{
					copyOK = true;
				}
				Preferences_ReleaseTagSet(&tagSet);
			}
			break;
		
		case kMy_SheetTypeTranslation:
			{
				Preferences_TagSetRef	tagSet = PrefPanelTranslations_NewTagSet();
				
				
				prefsResult = Preferences_ContextCopy(TerminalView_ReturnTranslationConfiguration(getActiveView(inPtr)),
														newContext.returnRef(), tagSet);
				if (kPreferences_ResultOK == prefsResult)
				{
					copyOK = true;
				}
				Preferences_ReleaseTagSet(&tagSet);
			}
			break;
		
		default:
			// ???
			break;
		}
		
		if (copyOK)
		{
			inPtr->sheetType = inSheetType;
			inPtr->recentSheetContext.setWithRetain(newContext.returnRef());
		}
		else
		{
			Console_Warning(Console_WriteLine, "failed to copy initial preferences into sheet context");
		}
	}
	
	result = inPtr->recentSheetContext.returnRef();
	
	return result;
}// sheetContextBegin


/*!
Destroys the temporary sheet preferences context, removing
the monitor on it, and clearing any flags that keep track of
active sheets.

(4.0)
*/
void
sheetContextEnd		(My_TerminalWindowPtr	inPtr)
{
	if (Preferences_ContextIsValid(inPtr->recentSheetContext.returnRef()))
	{
		inPtr->recentSheetContext.clear();
	}
	inPtr->sheetType = kMy_SheetTypeNone;
}// sheetContextEnd


/*!
Invoked whenever a monitored terminal state is changed
(see TerminalWindow_New() to see which states are monitored).
This routine responds by updating terminal windows
appropriately.

(3.0)
*/
void
terminalStateChanged	(ListenerModel_Ref		UNUSED_ARGUMENT(inUnusedModel),
						 ListenerModel_Event	inTerminalSettingThatChanged,
						 void*					inEventContextPtr,
						 void*					inListenerContextPtr)
{
	switch (inTerminalSettingThatChanged)
	{
	case kTerminal_ChangeAudioState:
		// update the bell toolbar item based on the bell being enabled or disabled
		{
			TerminalScreenRef	screen = REINTERPRET_CAST(inEventContextPtr, TerminalScreenRef);
			TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inListenerContextPtr, TerminalWindowRef);
			
			
			if (nullptr != terminalWindow)
			{
				My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
				HIToolbarItemRef				bellItem = nullptr;
				OSStatus						error = noErr;
				
				
				bellItem = REINTERPRET_CAST(ptr->toolbarItemBell.returnHIObjectRef(), HIToolbarItemRef);
				if (nullptr != bellItem)
				{
					error = HIToolbarItemSetIconRef(bellItem, (Terminal_BellIsEnabled(screen)) ? gBellOffIcon() : gBellOnIcon());
					assert_noerr(error);
				}
			}
		}
		break;
	
	case kTerminal_ChangeExcessiveErrors:
		// the terminal has finally had enough, having seen a ridiculous
		// number of data errors; report this to the user
		{
			//TerminalScreenRef	screen = REINTERPRET_CAST(inEventContextPtr, TerminalScreenRef);
			TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inListenerContextPtr, TerminalWindowRef);
			
			
			if (nullptr != terminalWindow)
			{
				My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
				AlertMessages_BoxWrap			box(Alert_NewWindowModal(TerminalWindow_ReturnNSWindow(terminalWindow)),
													AlertMessages_BoxWrap::kAlreadyRetained);
				CFRetainRelease					dialogTextCFString(UIStrings_ReturnCopy(kUIStrings_AlertWindowExcessiveErrorsPrimaryText),
																	CFRetainRelease::kAlreadyRetained);
				CFRetainRelease					helpTextCFString(UIStrings_ReturnCopy(kUIStrings_AlertWindowExcessiveErrorsHelpText),
																	CFRetainRelease::kAlreadyRetained);
				
				
				Alert_SetParamsFor(box.returnRef(), kAlert_StyleOK);
				Alert_SetIcon(box.returnRef(), kAlert_IconIDNote);
				
				assert(dialogTextCFString.exists());
				assert(helpTextCFString.exists());
				Alert_SetTextCFStrings(box.returnRef(), dialogTextCFString.returnCFStringRef(),
										helpTextCFString.returnCFStringRef());
				
				// show the message
				Alert_Display(box.returnRef()); // retains alert until it is dismissed
			}
		}
		break;
	
	case kTerminal_ChangeNewLEDState:
		// find the new LED state(s)
		{
			TerminalScreenRef	screen = REINTERPRET_CAST(inEventContextPtr, TerminalScreenRef);
			TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inListenerContextPtr, TerminalWindowRef);
			
			
			if ((nullptr != screen) && (nullptr != terminalWindow))
			{
				// find the 4 terminal LED states; update internal state, and the toolbar
				My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
				HIToolbarItemRef				relevantItem = nullptr;
				UInt16							i = 0;
				OSStatus						error = noErr;
				
				
				ptr->isLEDOn[i] = Terminal_LEDIsOn(screen, i + 1/* LED # */);
				relevantItem = REINTERPRET_CAST(ptr->toolbarItemLED1.returnHIObjectRef(), HIToolbarItemRef);
				if (nullptr != relevantItem)
				{
					error = HIToolbarItemSetIconRef(relevantItem, (ptr->isLEDOn[i]) ? gLEDOnIcon() : gLEDOffIcon());
					assert_noerr(error);
				}
				++i;
				
				ptr->isLEDOn[i] = Terminal_LEDIsOn(screen, i + 1/* LED # */);
				relevantItem = REINTERPRET_CAST(ptr->toolbarItemLED2.returnHIObjectRef(), HIToolbarItemRef);
				if (nullptr != relevantItem)
				{
					error = HIToolbarItemSetIconRef(relevantItem, (ptr->isLEDOn[i]) ? gLEDOnIcon() : gLEDOffIcon());
					assert_noerr(error);
				}
				++i;
				
				ptr->isLEDOn[i] = Terminal_LEDIsOn(screen, i + 1/* LED # */);
				relevantItem = REINTERPRET_CAST(ptr->toolbarItemLED3.returnHIObjectRef(), HIToolbarItemRef);
				if (nullptr != relevantItem)
				{
					error = HIToolbarItemSetIconRef(relevantItem, (ptr->isLEDOn[i]) ? gLEDOnIcon() : gLEDOffIcon());
					assert_noerr(error);
				}
				++i;
				
				ptr->isLEDOn[i] = Terminal_LEDIsOn(screen, i + 1/* LED # */);
				relevantItem = REINTERPRET_CAST(ptr->toolbarItemLED4.returnHIObjectRef(), HIToolbarItemRef);
				if (nullptr != relevantItem)
				{
					error = HIToolbarItemSetIconRef(relevantItem, (ptr->isLEDOn[i]) ? gLEDOnIcon() : gLEDOffIcon());
					assert_noerr(error);
				}
				++i;
			}
		}
		break;
	
	case kTerminal_ChangeScrollActivity:
		// recalculate appearance of the scroll bars to match current screen attributes, and redraw them
		{
			//Terminal_ScrollDescriptionConstPtr		scrollInfoPtr = REINTERPRET_CAST(inEventContextPtr, Terminal_ScrollDescriptionConstPtr); // not needed
			TerminalWindowRef					terminalWindow = REINTERPRET_CAST(inListenerContextPtr, TerminalWindowRef);
			
			
			if (nullptr != terminalWindow)
			{
				My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
				
				
				updateScrollBars(ptr);
			}
		}
		break;
	
	case kTerminal_ChangeWindowFrameTitle:
		// set window’s title to match
		{
			TerminalScreenRef	screen = REINTERPRET_CAST(inEventContextPtr, TerminalScreenRef);
			TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inListenerContextPtr, TerminalWindowRef);
			
			
			if (nullptr != terminalWindow)
			{
				My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
				CFStringRef						titleCFString = nullptr;
				
				
				Terminal_CopyTitleForWindow(screen, titleCFString);
				if (nullptr != titleCFString)
				{
					TerminalWindow_SetWindowTitle(ptr->selfRef, titleCFString);
					CFRelease(titleCFString), titleCFString = nullptr;
				}
			}
		}
		break;
	
	case kTerminal_ChangeWindowIconTitle:
		// set window’s alternate (Dock icon) title to match
		{
		@autoreleasepool {
			TerminalScreenRef	screen = REINTERPRET_CAST(inEventContextPtr, TerminalScreenRef);
			TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inListenerContextPtr, TerminalWindowRef);
			
			
			if (nullptr != terminalWindow)
			{
				My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
				CFStringRef						titleCFString = nullptr;
				
				
				Terminal_CopyTitleForIcon(screen, titleCFString);
				if (nullptr != titleCFString)
				{
					// TEMPORARY - Cocoa wrapper window does not seem to recognize setMiniwindowTitle:,
					// so the Carbon call is also used in the meantime
					UNUSED_RETURN(OSStatus)SetWindowAlternateTitle(returnCarbonWindow(ptr), titleCFString);
					
					[ptr->window setMiniwindowTitle:(NSString*)titleCFString];
					
					CFRelease(titleCFString), titleCFString = nullptr;
				}
			}
		}// @autoreleasepool
		}
		break;
	
	case kTerminal_ChangeWindowMinimization:
		// minimize or restore window based on requested minimization
		{
		@autoreleasepool {
			TerminalScreenRef	screen = REINTERPRET_CAST(inEventContextPtr, TerminalScreenRef);
			TerminalWindowRef	terminalWindow = REINTERPRET_CAST(inListenerContextPtr, TerminalWindowRef);
			
			
			if (nullptr != terminalWindow)
			{
				My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), terminalWindow);
				
				
				if (Terminal_WindowIsToBeMinimized(screen))
				{
					[ptr->window miniaturize:nil];
				}
				else
				{
					[ptr->window deminiaturize:nil];
				}
			}
		}// @autoreleasepool
		}
		break;
	
	default:
		// ???
		break;
	}
}// terminalStateChanged


/*!
Invoked whenever a monitored terminal view event occurs (see
TerminalWindow_New() to see which events are monitored).
This routine responds by updating terminal windows appropriately.

(3.1)
*/
void
terminalViewStateChanged	(ListenerModel_Ref		UNUSED_ARGUMENT(inUnusedModel),
							 ListenerModel_Event	inTerminalViewEvent,
							 void*					inEventContextPtr,
							 void*					inListenerContextPtr)
{
	TerminalWindowRef				ref = REINTERPRET_CAST(inListenerContextPtr, TerminalWindowRef);
	My_TerminalWindowAutoLocker		ptr(gTerminalWindowPtrLocks(), ref);
	
	
	// currently, only one type of event is expected
	assert((inTerminalViewEvent == kTerminalView_EventScrolling) ||
			(inTerminalViewEvent == kTerminalView_EventSearchResultsExistence));
	
	switch (inTerminalViewEvent)
	{
	case kTerminalView_EventScrolling:
		// recalculate appearance of the scroll bars to match current screen attributes, and redraw them
		{
			//TerminalViewRef	view = REINTERPRET_CAST(inEventContextPtr, TerminalViewRef); // not needed
			
			
			updateScrollBars(ptr);
			UNUSED_RETURN(OSStatus)HIViewSetNeedsDisplay(ptr->controls.scrollBarH, true);
			UNUSED_RETURN(OSStatus)HIViewSetNeedsDisplay(ptr->controls.scrollBarV, true);
		}
		break;
	
	case kTerminalView_EventSearchResultsExistence:
		// search results either appeared or disappeared; ensure the scroll bar
		// rendering is only installed when it is needed
		{
			TerminalViewRef		view = REINTERPRET_CAST(inEventContextPtr, TerminalViewRef);
			
			
			if (TerminalView_SearchResultsExist(view))
			{
				installTickHandler(ptr);
			}
			else
			{
				ptr->scrollTickHandler.remove();
				assert(false == ptr->scrollTickHandler.isInstalled());
			}
			UNUSED_RETURN(OSStatus)HIViewSetNeedsDisplay(ptr->controls.scrollBarH, true);
			UNUSED_RETURN(OSStatus)HIViewSetNeedsDisplay(ptr->controls.scrollBarV, true);
		}
		break;
	
	default:
		// ???
		break;
	}
}// terminalViewStateChanged


/*!
Updates the values and view sizes of the scroll bars
to show the position and percentage of the total
screen area that is currently visible in the window.

(3.0)
*/
void
updateScrollBars	(My_TerminalWindowPtr	inPtr)
{
	if (false == inPtr->allViews.empty())
	{
		// update the scroll bars to reflect the contents of the selected view
		TerminalViewRef			view = getActiveView(inPtr);
		HIViewRef				scrollBarView = nullptr;
		SInt32					scrollVStartView = 0;
		SInt32					scrollVPastEndView = 0;
		SInt32					scrollVRangeMinimum = 0;
		SInt32					scrollVRangePastMaximum = 0;
		TerminalView_Result		rangeResult = kTerminalView_ResultOK;
		
		
		// use the maximum possible screen size for the maximum resize limits
		rangeResult = TerminalView_GetScrollVerticalInfo(view, scrollVStartView, scrollVPastEndView,
															scrollVRangeMinimum, scrollVRangePastMaximum);
		assert(kTerminalView_ResultOK == rangeResult);
		
		// update controls’ maximum and minimum values; the vertical scroll bar
		// is special, in that its maximum value is zero (this ensures the main
		// area is pinned in view even if new scrollback rows show up, etc.)
		scrollBarView = inPtr->controls.scrollBarH;
		SetControl32BitMinimum(scrollBarView, 0);
		SetControl32BitMaximum(scrollBarView, 0);
		SetControl32BitValue(scrollBarView, 0);
		SetControlViewSize(scrollBarView, 0);
		scrollBarView = inPtr->controls.scrollBarV;
		SetControl32BitMinimum(scrollBarView, scrollVRangeMinimum);
		SetControl32BitMaximum(scrollBarView, scrollVRangePastMaximum - (scrollVPastEndView - scrollVStartView)/* subtract last page */);
		SetControl32BitValue(scrollBarView, scrollVStartView);
		
		// set the size of the scroll thumb, but refuse to make it as ridiculously
		// tiny as Apple allows; artificially require it to be bigger
		{
			UInt32		proposedViewSize = scrollVPastEndView - scrollVStartView;
			HIRect		scrollBarBounds;
			Float64		viewDenominator = (STATIC_CAST(GetControl32BitMaximum(scrollBarView), Float32) -
											STATIC_CAST(GetControl32BitMinimum(scrollBarView), Float32));
			Float64		viewScale = STATIC_CAST(proposedViewSize, Float32) / viewDenominator;
			Float64		barScale = 0;
			
			
			UNUSED_RETURN(OSStatus)HIViewGetBounds(scrollBarView, &scrollBarBounds);
			
			// adjust the numerator to require a larger minimum size for the thumb
			barScale = kMy_ScrollBarThumbMinimumSize / (scrollBarBounds.size.height - 2 * kMy_ScrollBarArrowHeight);
			if (viewScale < barScale)
			{
				proposedViewSize = STATIC_CAST(barScale * viewDenominator, UInt32);
			}
			
			SetControlViewSize(scrollBarView, proposedViewSize);
		}
		
		UNUSED_RETURN(OSStatus)HIViewSetNeedsDisplay(inPtr->controls.scrollBarV, true);
		UNUSED_RETURN(OSStatus)HIViewSetNeedsDisplay(inPtr->controls.scrollBarH, true);
	}
}// updateScrollBars

} // anonymous namespace


#pragma mark -
@implementation TerminalWindow_Controller //{


@synthesize terminalWindowRef = _terminalWindowRef;


#pragma mark Initializers


/*!
A temporary initializer for creating a terminal window frame
that wraps an experimental, Cocoa-based terminal view.

Eventually, this will be the basis for the default interface.

(2016.03)
*/
- (instancetype)
initWithTerminalVC:(TerminalView_Controller*)	aViewController
{
	self = [super initWithWindowNibName:@"TerminalWindowCocoa"];
	if (nil != self)
	{
		self->_terminalWindowRef = nil;
		
		// TEMPORARY; view controller is ignored for now, using
		// only the view itself
		[REINTERPRET_CAST(self.window.contentView, NSView*) addSubview:aViewController.view];
		
		// create toolbar; has to be done programmatically, because
		// IB only supports them in 10.5; which makes sense, you know,
		// since toolbars have only been in the OS since 10.0, and
		// hardly any applications would have found THOSE useful...
		{
			NSString*		toolbarID = @"TerminalToolbar"; // do not ever change this; that would only break user preferences
			NSToolbar*		windowToolbar = [[[NSToolbar alloc] initWithIdentifier:toolbarID] autorelease];
			
			
			self->_toolbarDelegate = [[TerminalToolbar_Delegate alloc] initForToolbar:windowToolbar
																						experimentalItems:YES];
			[windowToolbar setAllowsUserCustomization:YES];
			[windowToolbar setAutosavesConfiguration:YES];
			[windowToolbar setDelegate:self->_toolbarDelegate];
			[self.window setToolbar:windowToolbar];
		}
		
		// "canDrawConcurrently" is YES for terminal background views
		// so enable concurrent view drawing at the window level
		[self.window setAllowsConcurrentViewDrawing:YES];
	}
	return self;
}// initWithTerminalVC:


/*!
Destructor.

(2016.03)
*/
- (void)
dealloc
{
	[self->_toolbarDelegate release];
	[super dealloc];
}// dealloc


@end //} TerminalWindow_Controller


#pragma mark -
@implementation TerminalWindow_ResizeInfoController


static TerminalWindow_ResizeInfoController*		gTerminalWindow_ResizeInfoController = nil;


@synthesize resizeInfoText = _resizeInfoText;


/*!
Returns the singleton.

(4.1)
*/
+ (TerminalWindow_ResizeInfoController*)
sharedTerminalWindowResizeInfoController
{
	if (nil == gTerminalWindow_ResizeInfoController)
	{
		gTerminalWindow_ResizeInfoController = [[self.class allocWithZone:NULL] init];
	}
	return gTerminalWindow_ResizeInfoController;
}// sharedTerminalWindowResizeInfoController


/*!
Designated initializer.

(4.1)
*/
- (instancetype)
init
{
	self = [super initWithWindowNibName:@"ResizeInfoCocoa"];
	return self;
}// init


@end // TerminalWindow_ResizeInfoController


#pragma mark -
@implementation NSWindow (TerminalWindow_NSWindowExtensions)


/*!
Returns any Terminal Window that is associated with an NSWindow,
or nullptr if there is none.

(4.0)
*/
- (TerminalWindowRef)
terminalWindowRef
{
	auto				toPair = gCarbonTerminalWindowRefsByNSWindow().find(self);
	TerminalWindowRef	result = nullptr;
	
	
	if (gCarbonTerminalWindowRefsByNSWindow().end() != toPair)
	{
		result = toPair->second;
	}
	else
	{
		toPair = gTerminalWindowRefsByNSWindow().find(self);
		if (gTerminalWindowRefsByNSWindow().end() != toPair)
		{
			result = toPair->second;
		}
	}
	return result;
}// terminalWindowRef


@end // NSWindow (TerminalWindow_NSWindowExtensions)

// BELOW IS REQUIRED NEWLINE TO END FILE
