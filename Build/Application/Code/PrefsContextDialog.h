/*!	\file PrefsContextDialog.h
	\brief Implements a dialog that can host any panel capable
	of editing settings in a "Preferences_ContextRef" (namely,
	those normally used in the Preferences window).
	
	This is an extremely convenient way to edit a temporary
	copy of settings that could also have global defaults.
	The vast majority of terminal-specific sheets are
	therefore trivial to implement.
*/
/*###############################################################

	MacTelnet
		� 1998-2009 by Kevin Grant.
		� 2001-2003 by Ian Anderson.
		� 1986-1994 University of Illinois Board of Trustees
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

#ifndef __PREFSCONTEXTDIALOG__
#define __PREFSCONTEXTDIALOG__

// Mac includes
#include <CoreServices/CoreServices.h>

// MacTelnet includes
#include "GenericDialog.h"
#include "Panel.h"
#include "Preferences.h"



#pragma mark Types

typedef struct PrefsContextDialog_OpaqueStruct*		PrefsContextDialog_Ref;



#pragma mark Public Methods

PrefsContextDialog_Ref
	PrefsContextDialog_New					(HIWindowRef						inParentWindowOrNullForModalDialog,
											 Panel_Ref							inHostedPanel,
											 Preferences_ContextRef				inoutData);

void
	PrefsContextDialog_Dispose				(PrefsContextDialog_Ref*			inoutDialogPtr);

void
	PrefsContextDialog_Display				(PrefsContextDialog_Ref				inDialog);

GenericDialog_Ref
	PrefsContextDialog_ReturnGenericDialog	(PrefsContextDialog_Ref				inDialog);

#endif

// BELOW IS REQUIRED NEWLINE TO END FILE