/*!	\file VectorInterpreter.h
	\brief Takes Tektronix codes as input, and sends the output
	to real graphics devices.
	
	Developed by Aaron Contorer, with bug fixes by Tim Krauskopf.
	TEK 4105 additions by Dave Whittington.
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
#include <CoreServices/CoreServices.h>

// application includes
#include "VectorCanvas.h"
#include "VectorInterpreterRef.typedef.h"



#pragma mark Constants

/*!
These represent the largest values allowed in
graphics screen coordinates.
*/
enum
{
	kVectorInterpreter_MaxX		= 4096,
	kVectorInterpreter_MaxY		= 4096
};

/*!
The command set, which determines how input data streams
are interpreted.
*/
typedef UInt16 VectorInterpreter_Mode;
enum
{
	kVectorInterpreter_ModeDisabled		= 0,	//!< TEK 4014 command set
	kVectorInterpreter_ModeTEK4014		= 4014,	//!< TEK 4014 command set
	kVectorInterpreter_ModeTEK4105		= 4105	//!< TEK 4105 command set
};



#pragma mark Public Methods

//!\name Creating and Destroying Graphics
//@{

VectorInterpreter_Ref
	VectorInterpreter_New					(VectorInterpreter_Mode		inCommandSet);

void
	VectorInterpreter_Retain				(VectorInterpreter_Ref		inGraphicID);

void
	VectorInterpreter_Release				(VectorInterpreter_Ref*		inoutGraphicIDPtr);

//@}

//!\name Manipulating Graphics
//@{

void
	VectorInterpreter_CopyZoom				(VectorInterpreter_Ref		inDestinationGraphicID,
											 VectorInterpreter_Ref		inSourceGraphicID);

void
	VectorInterpreter_PageCommand			(VectorInterpreter_Ref		inGraphicID);

size_t
	VectorInterpreter_ProcessData			(VectorInterpreter_Ref		inGraphicID,
											 UInt8 const*				inDataPtr,
											 size_t						inDataSize);

void
	VectorInterpreter_Redraw				(VectorInterpreter_Ref		inGraphicID,
											 VectorInterpreter_Ref		inDestinationGraphicID);

SInt16
	VectorInterpreter_ReturnBackgroundColor	(VectorInterpreter_Ref		inGraphicID);

VectorCanvas_Ref
	VectorInterpreter_ReturnCanvas			(VectorInterpreter_Ref		inGraphicID);

void
	VectorInterpreter_SetPageClears			(VectorInterpreter_Ref		inGraphicID,
											 Boolean					inTrueClearsFalseNewWindow);

void
	VectorInterpreter_Zoom					(VectorInterpreter_Ref		inGraphicID,
											 SInt16						inX0,
											 SInt16						inY0,
											 SInt16						inX1,
											 SInt16						inY1);

//@}

//!\name Miscellaneous
//@{

SInt16
	VectorInterpreter_FillInPositionReport	(VectorInterpreter_Ref		inGraphicID,
											 UInt16						inX,
											 UInt16						inY,
											 char						inKeyPress,
											 char*						outPositionReportLength5);

VectorInterpreter_Mode
	VectorInterpreter_ReturnMode			(VectorInterpreter_Ref		inGraphicID);

//@}

// BELOW IS REQUIRED NEWLINE TO END FILE
