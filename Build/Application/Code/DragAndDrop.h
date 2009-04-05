/*!	\file DragAndDrop.h
	\brief Drag-and-drop management.
	
	Significant enhancements have been made in MacTelnet 3.0 to
	allow more drag capabilities (such as dropping text in
	movable, modal dialogs) and more supported drag flavors.
	There are also some new APIs to make deciphering drops more
	convenient.
*/
/*###############################################################

	MacTelnet
		© 1998-2006 by Kevin Grant.
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

#include "UniversalDefines.h"

#ifndef __DRAGANDDROP__
#define __DRAGANDDROP__



#pragma mark Constants

FourCharCode const			kDragFlavorTypeMacRomanText = 'TEXT';



#pragma mark Public Methods

//!\name Initialization
//@{

void
	DragAndDrop_Init						();

//@}

//!\name Drag Manager Availability
//@{

Boolean
	DragAndDrop_Available					();

//@}

//!\name Determining Drag Information (Efficient)
//@{

Boolean
	DragAndDrop_DragIsExactlyOneFile		(DragRef		inDrag);

UInt16
	DragAndDrop_ReturnDragItemCount			(DragRef		inDrag);

//@}

//!\name Drag Highlighting
//@{

void
	DragAndDrop_HideHighlightBackground		(CGContextRef	inPort,
											 CGRect const&	inArea);

// DEPRECATED - USE THE CORE GRAPHICS VERSION INSTEAD
void
	DragAndDrop_HideHighlightBackground		(CGrafPtr		inPort,
											 Rect const*	inAreaPtr);

void
	DragAndDrop_HideHighlightFrame			(CGContextRef	inPort,
											 CGRect const&	inArea);

// DEPRECATED - USE THE CORE GRAPHICS VERSION INSTEAD
void
	DragAndDrop_HideHighlightFrame			(CGrafPtr		inPort,
											 Rect const*	inAreaPtr);

void
	DragAndDrop_ShowHighlightBackground		(CGContextRef	inPort,
											 CGRect const&	inArea);

// DEPRECATED - USE THE CORE GRAPHICS VERSION INSTEAD
void
	DragAndDrop_ShowHighlightBackground		(CGrafPtr		inPort,
											 Rect const*	inAreaPtr);

void
	DragAndDrop_ShowHighlightFrame			(CGContextRef	inPort,
											 CGRect const&	inArea);

// DEPRECATED - USE THE CORE GRAPHICS VERSION INSTEAD
void
	DragAndDrop_ShowHighlightFrame			(CGrafPtr		inPort,
											 Rect const*	inAreaPtr);

//@}

#endif


// BELOW IS REQUIRED NEWLINE TO END FILE
