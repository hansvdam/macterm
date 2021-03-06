/*!	\file TranslucentMenuArrow.mm
	\brief A menu view that can appear to integrate
	into unusual backgrounds, such as window frames.
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

#import "TranslucentMenuArrow.h"

// Mac includes
#import <Cocoa/Cocoa.h>

// library includes
#import <Console.h>

// application includes
#import "RegionUtilities.h"



#pragma mark Internal Methods

#pragma mark -
@implementation TranslucentMenuArrow_View


/*!
Designated initializer.

(4.0)
*/
- (instancetype)
initWithFrame:(NSRect)		frameRect
{
	self = [super initWithFrame:frameRect];
	if (nil != self)
	{
		self->trackingRectTag = 0;
		self->hoverState = NO;
	}
	return self;
}// initWithFrame:


/*!
Installs a tracking rectangle for the cursor to handle the
hovering effect.

(4.0)
*/
- (void)
installTrackingRect
{
	// keep the cursor boundaries inset slightly, so that they
	// will overlap the clickable menu and not the outer frame
	NSRect		hotRect = NSInsetRect([self visibleRect], 3.0, 3.0);
	NSPoint		mouseLocation = [self convertPoint:[[self window] mouseLocationOutsideOfEventStream] fromView:nil];
	BOOL		isInside = (self == [self hitTest:mouseLocation]);
	
	
	self->trackingRectTag = [self addTrackingRect:hotRect owner:self userData:nil assumeInside:isInside];
}// installTrackingRect


/*!
Removes the tracking rectangle that was installed by
"installTrackingRect".

(4.0)
*/
- (void)
removeTrackingRect
{
	[self removeTrackingRect:self->trackingRectTag];
}// removeTrackingRect


#pragma mark NSResponder


- (void)
mouseEntered:(NSEvent*)		event
{
#pragma unused(event)
	self->hoverState = YES;
	[self display];
}// mouseEntered:


- (void)
mouseExited:(NSEvent*)		event
{
#pragma unused(event)
	self->hoverState = NO;
	[self display];
}// mouseExited:


#pragma mark NSView


/*!
Draws a mostly-transparent view; it must have at least
some slight content (e.g. at a low alpha value) in order
to be clickable however.

(4.0)
*/
- (void)
drawRect:(NSRect)	aRect
{
	NSGraphicsContext*	contextMgr = [NSGraphicsContext currentContext];
	CGContextRef		drawingContext = (CGContextRef)[contextMgr graphicsPort];
	NSRect				entireRect = [self bounds];
	CGRect				regionBounds = CGRectMake(aRect.origin.x, aRect.origin.y,
													aRect.size.width, aRect.size.height);
	CGRect				contentBounds = CGRectMake(entireRect.origin.x, entireRect.origin.y,
													entireRect.size.width, entireRect.size.height);
	id					firstSubview = ([[self subviews] count] > 0)
										? [[self subviews] objectAtIndex:0]
										: nil;
	NSControl*			asControl = ((nil != firstSubview) && [firstSubview isKindOfClass:[NSControl class]])
										? (NSControl*)firstSubview
										: nil;
	BOOL				isEnabled = (nil != asControl)
									? [asControl isEnabled]
									: YES;
	
	
	CGContextClearRect(drawingContext, regionBounds);
	
	// draw the main content a few pixels inside
	contentBounds = CGRectInset(contentBounds, 2.0, 2.0); // arbitrary distance
	
	// draw a translucent, filled circle
	CGContextSetRGBFillColor(drawingContext, 0, 0, 0, ((self->hoverState) && (isEnabled)) ? 0.3f : 0.1f/* alpha */);
	CGContextBeginPath(drawingContext);
	if (contentBounds.size.width == contentBounds.size.height)
	{
		// perfect square; make a circle
		CGContextAddArc(drawingContext, contentBounds.origin.x + CGFLOAT_DIV_2(contentBounds.size.width),
						contentBounds.origin.y + CGFLOAT_DIV_2(contentBounds.size.height),
						CGFLOAT_DIV_2(contentBounds.size.width)/* radius */,
						0/* start angle */, STATIC_CAST(2 * M_PI, Float32)/* end angle */, YES/* clockwise */);
	}
	else
	{
		// not square; use a rounded rectangle
		RegionUtilities_AddRoundedRectangleToPath(drawingContext, contentBounds, contentBounds.size.height / 3.0f/* curve width */,
													contentBounds.size.height / 3.0f/* curve height */);
	}
	CGContextClosePath(drawingContext);
	CGContextFillPath(drawingContext);
	
	// draw an arrow in Yosemite style
	{
		// NOTE: cannot use CGRectGetMidX(), etc. because they are not constant expressions
		CGFloat const	kMidX = (contentBounds.origin.x + CGFLOAT_DIV_2(contentBounds.size.width));
		CGFloat const	kMidY = (contentBounds.origin.y + CGFLOAT_DIV_2(contentBounds.size.height));
		CGPoint			points[] =
						{
							{ kMidX - 3.0f/* arbitrary */, kMidY + 1.5f/* arbitrary */ },
							{ kMidX, kMidY - 1.5f/* arbitrary */ },
							{ kMidX, kMidY - 1.5f/* arbitrary */ },
							{ kMidX + 3.0f/* arbitrary */, kMidY + 1.5f/* arbitrary */ },
						};
		
		
		CGContextSetRGBStrokeColor(drawingContext, 0, 0, 0, ((self->hoverState) && (isEnabled)) ? 0.5f : 0.3f/* alpha */);
		CGContextSetLineWidth(drawingContext, 1.5);
		CGContextSetLineCap(drawingContext, kCGLineCapRound);
		CGContextSetLineJoin(drawingContext, kCGLineJoinRound);
		CGContextStrokeLineSegments(drawingContext, points, sizeof(points) / sizeof(CGPoint));
	}
}// drawRect:


/*!
Called by the system when the view has moved to another window
(or no window).  Handled by setting up tracking rectangles.

(4.0)
*/
- (void)
viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	if (nil != [self window])
	{
		[self installTrackingRect];
	}
}// viewDidMoveToWindow


/*!
Called by the system when the view is about to move to another
window (or no window).  Handled by removing tracking rectangles.

(4.0)
*/
- (void)
viewWillMoveToWindow:(NSWindow*)	aWindow
{
	[super viewWillMoveToWindow:aWindow];
	if ((nil == aWindow) && (nil != [self window]))
	{
		[self removeTrackingRect];
	}
}// viewDidMoveToWindow


@end // TranslucentMenuArrow_View

// BELOW IS REQUIRED NEWLINE TO END FILE
