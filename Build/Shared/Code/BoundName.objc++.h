/*!	\file BoundName.objc++.h
	\brief An object with a stable name-string binding.
*/
/*###############################################################

	Simple Cocoa Wrappers Library
	© 2008-2017 by Kevin Grant
	
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
#import <Cocoa/Cocoa.h>

// library includes
#import <CocoaFuture.objc++.h>



#pragma mark Types

/*!
Since some older versions of Mac OS X do not bind "description"
reliably, this exposes a string property that always has the
same meaning on any version of Mac OS X.  It is recommended
that user interface elements use "boundName" for bindings
instead of "description".
*/
@interface BoundName_Object : NSObject //{
{
	NSString*	boundNameString_;
}

// initializers
	- (instancetype)
	init;
	- (instancetype)
	initWithBoundName:(NSString*)_ NS_DESIGNATED_INITIALIZER;

// accessors
	- (NSString*)
	boundName;
	- (void)
	setBoundName:(NSString*)_;
	- (NSString*)
	description;
	- (void)
	setDescription:(NSString*)_;

@end //}

// BELOW IS REQUIRED NEWLINE TO END FILE
