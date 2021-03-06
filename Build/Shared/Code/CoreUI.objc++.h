/*!	\file CoreUI.objc++.h
	\brief Implements base user interface elements.
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

#include <UniversalDefines.h>

#pragma once

// Mac includes
#import <Cocoa/Cocoa.h>



#pragma mark Types

/*!
Custom subclass for action buttons in order to provide
a way to customize behavior when needed.

This customizes the focus-ring layout and rendering to
correct display glitches in layer-backed hierarchies.
(Theoretically these can be fixed by adopting later
SDKs but for now this is the only way forward.)

Note that this is only in the header for the sake of
Interface Builder, which will not synchronize with
changes to an interface declared in a ".mm" file.
*/
@interface CoreUI_Button : NSButton //{

// NSView
	- (void)
	drawFocusRingMask;
	- (void)
	drawRect:(NSRect)_;
	- (NSRect)
	focusRingMaskBounds;

@end //}


/*!
Custom subclass for color wells in order to provide
a way to customize behavior when needed.

This customizes the focus-ring layout and rendering to
correct display glitches in layer-backed hierarchies.
(Theoretically these can be fixed by adopting later
SDKs but for now this is the only way forward.)

Note that this is only in the header for the sake of
Interface Builder, which will not synchronize with
changes to an interface declared in a ".mm" file.
*/
@interface CoreUI_ColorButton : NSColorWell //{

// NSView
	- (void)
	drawFocusRingMask;
	- (void)
	drawRect:(NSRect)_;
	- (NSRect)
	focusRingMaskBounds;

@end //}


/*!
Custom subclass for help buttons in order to provide
a way to customize behavior when needed.

This customizes the focus-ring layout and rendering to
correct display glitches in layer-backed hierarchies.
(Theoretically these can be fixed by adopting later
SDKs but for now this is the only way forward.)

Note that this is only in the header for the sake of
Interface Builder, which will not synchronize with
changes to an interface declared in a ".mm" file.
*/
@interface CoreUI_HelpButton : NSButton //{

// NSView
	- (void)
	drawFocusRingMask;
	- (void)
	drawRect:(NSRect)_;
	- (NSRect)
	focusRingMaskBounds;

@end //}


/*!
Custom subclass for menu buttons in order to provide
a way to customize behavior when needed.

This customizes the focus-ring layout and rendering to
correct display glitches in layer-backed hierarchies.
(Theoretically these can be fixed by adopting later
SDKs but for now this is the only way forward.)

Note that this is only in the header for the sake of
Interface Builder, which will not synchronize with
changes to an interface declared in a ".mm" file.
*/
@interface CoreUI_MenuButton : NSPopUpButton //{

// NSView
	- (void)
	drawFocusRingMask;
	- (void)
	drawRect:(NSRect)_;
	- (NSRect)
	focusRingMaskBounds;

@end //}


/*!
Custom subclass for scroll views in order to provide
a way to customize behavior when needed.

Note that this is only in the header for the sake of
Interface Builder, which will not synchronize with
changes to an interface declared in a ".mm" file.
*/
@interface CoreUI_ScrollView : NSScrollView //{

@end //}


/*!
Custom subclass for square buttons in order to provide
a way to customize behavior when needed.

This customizes the focus-ring layout and rendering to
correct display glitches in layer-backed hierarchies.
(Theoretically these can be fixed by adopting later
SDKs but for now this is the only way forward.)

Note that this is only in the header for the sake of
Interface Builder, which will not synchronize with
changes to an interface declared in a ".mm" file.
*/
@interface CoreUI_SquareButton : NSButton //{

// NSView
	- (void)
	drawFocusRingMask;
	- (void)
	drawRect:(NSRect)_;
	- (NSRect)
	focusRingMaskBounds;

@end //}


/*!
Custom subclass for square button cells in order to
provide a way to customize behavior when needed.

This customizes the focus-ring layout and rendering to
correct display glitches in layer-backed hierarchies.
(Theoretically these can be fixed by adopting later
SDKs but for now this is the only way forward.)

Note that this is only in the header for the sake of
Interface Builder, which will not synchronize with
changes to an interface declared in a ".mm" file.
*/
@interface CoreUI_SquareButtonCell : NSButtonCell //{

// NSCell
	- (void)
	drawFocusRingMaskWithFrame:(NSRect)_
	inView:(NSView*)_;
	- (NSRect)
	focusRingMaskBoundsForFrame:(NSRect)_
	inView:(NSView*)_;

@end //}


/*!
Custom subclass for table views in order to provide
a way to customize behavior when needed.

This customizes the focus-ring layout and rendering to
correct display glitches in layer-backed hierarchies.
(Theoretically these can be fixed by adopting later
SDKs but for now this is the only way forward.)

Note that this is only in the header for the sake of
Interface Builder, which will not synchronize with
changes to an interface declared in a ".mm" file.
*/
@interface CoreUI_Table : NSTableView //{

@end //}

// BELOW IS REQUIRED NEWLINE TO END FILE
