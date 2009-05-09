#!/usr/bin/python
# vim: set fileencoding=UTF-8 :
"""Routines to open various types of files.
"""
__author__ = 'Kevin Grant <kevin@ieee.org>'
__date__ = '1 January 2008'
__version__ = '4.0.0'

import sys
import pymactelnet.file.kvp
# note: Quills is a compiled module, library path must be set properly
import Quills

def macros(pathname):
    """macros(pathname) -> None
    
    Load macros from the given ".macros" file, by parsing the
    file and assuming that the first up to 12 keys have values
    representing strings to be sent.  (This is a limitation of
    the original file format, that might be avoidable if a
    transition to XML is made in the future.)
    Raise SyntaxError if the file is not formatted properly.
    Raise KeyError if the file is successfully parsed but it has
    no keys that apparently represent macros (macro key names
    should look like "f1", "f2", ... or "m0", "m1", ...).
    
    WARNING: This routine is incomplete, as the Quills API has
    not advanced far enough to make use of all of the settings
    that could exist in a ".macros" file.
    
    TEMPORARY: This should probably be separated into a
    routine that converts macros files into Quills.Prefs
    objects, and a routine that is a file-open handler that
    actually enables those macro preferences.  Right now, this
    is doing both.
    
    """
    sfile = open(pathname, 'rU')
    try:
        parser = pymactelnet.file.kvp.Parser(file_object=sfile)
        defs = parser.results()
        macro_set = Quills.Prefs(Quills.Prefs.MACRO_SET)
        for key in defs:
            data = defs[key]
            first_part = key.rstrip('0123456789')
            second_part = key.replace(first_part, "")
            number = int(second_part)
            # need a one-based index, files normally start with 0 (except F1...)
            if first_part != "f" and first_part != "F": number += 1
            macro_set.define_macro(number, name="Macro %i" % number, contents=data)
        Quills.Prefs.set_current_macros(macro_set)
    finally:
        sfile.close()

def script(pathname):
    """script(pathname) -> None
    
    Asynchronously open a session from the given script file, by
    running the script!  Raise an exception on failure.
    
    """
    args = [pathname]
    session = Quills.Session(args)

def session(pathname):
    """session(pathname) -> None
    
    Asynchronously open a session from the given ".session" file,
    by parsing the file for command information, and trying to
    use other information from the file to configure the session
    and its terminal window.
    Raise SyntaxError if the file is not formatted properly.
    Raise KeyError if the file is successfully parsed but it has
    no command information.
    
    WARNING: This routine is incomplete, as the Quills API has
    not advanced far enough to make use of all of the settings
    that could exist in a ".session" file.
    
    """
    sfile = open(pathname, 'rU')
    try:
        parser = pymactelnet.file.kvp.Parser(file_object=sfile)
        defs = parser.results()
        if 'command' in defs:
            args = defs['command'].split()
            session = Quills.Session(args)
        else:
            raise KeyError('no "command" was found in the file')
    finally:
        sfile.close()

def _test():
    import doctest, pymactelnet.file.open
    return doctest.testmod(pymactelnet.file.open)