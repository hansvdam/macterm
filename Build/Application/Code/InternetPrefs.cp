/*!	\file InternetPrefs.cp
	\brief Legacy; may need to be removed.
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

#include "InternetPrefs.h"
#include <UniversalDefines.h>

// Mac includes
#include <CoreServices/CoreServices.h>

// library includes
#include <Console.h>

// application includes
#include "AppResources.h"



#pragma mark Variables
namespace {

ICInstance		gInternetConfigInstance = nullptr;

} // anonymous namespace



#pragma mark Public Methods

/*!
Call this method once before using any
other routines from this module.

(2.6)
*/
void
InternetPrefs_Init ()
{
	OSStatus		error = noErr;
	ICDirSpecArray	folderSpec;
	
	
	error = ICStart(&gInternetConfigInstance, AppResources_ReturnCreatorCode());
	if (noErr != error)
	{
		Console_Warning(Console_WriteValue, "unable to initialize InternetPrefs module, error", error);
	}
	
	folderSpec[0].vRefNum = -1; // -1 = search for system preferences
	folderSpec[0].dirID = 2;
}// Init

// BELOW IS REQUIRED NEWLINE TO END FILE
