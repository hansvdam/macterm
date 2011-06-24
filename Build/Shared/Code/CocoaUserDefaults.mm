/*!	\file CocoaUserDefaults.mm
	\brief NSUserDefaults Cocoa APIs wrapped in C++.
*/
/*###############################################################

	Simple Cocoa Wrappers Library 1.7
	© 2008-2011 by Kevin Grant
	
	This library is free software; you can redistribute it or
	modify it under the terms of the GNU Lesser Public License
	as published by the Free Software Foundation; either version
	2.1 of the License, or (at your option) any later version.
	
	This program is distributed in the hope that it will be
	useful, but WITHOUT ANY WARRANTY; without even the implied
	warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
	PURPOSE.  See the GNU Lesser Public License for details.
	
	You should have received a copy of the GNU Lesser Public
	License along with this library; if not, write to:
	
		Free Software Foundation, Inc.
		59 Temple Place, Suite 330
		Boston, MA  02111-1307
		USA

###############################################################*/

// Mac includes
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>

// library includes
#import <AutoPool.objc++.h>
#import <CocoaUserDefaults.h>



#pragma mark Public Methods

/*!
Copies the specified preferences domain entirely (e.g.
taking the contents of ~/Library/Preferences/<fromName>.plist
and creating ~/Library/Preferences/<toName>.plist).

IMPORTANT:	The copy is not saved until preferences have been
			synchronized.

(1.7)
*/
void
CocoaUserDefaults_CopyDomain	(CFStringRef	inFromName,
								 CFStringRef	inToName)
{
	AutoPool			_;
	NSUserDefaults*		defaultsTarget = [NSUserDefaults standardUserDefaults];
	NSDictionary*		dataDictionary = [defaultsTarget persistentDomainForName:(NSString*)inFromName];
	
	
	[defaultsTarget setPersistentDomain:dataDictionary forName:(NSString*)inToName];
}// CopyDomain


/*!
Removes the specified preferences domain entirely (e.g.
deleting its ~/Library/Preferences/<name>.plist file).

(1.0)
*/
void
CocoaUserDefaults_DeleteDomain	(CFStringRef	inName)
{
	AutoPool	_;
	
	
	[[NSUserDefaults standardUserDefaults] removePersistentDomainForName:(NSString*)inName];
}// DeleteDomain

// BELOW IS REQUIRED NEWLINE TO END FILE
