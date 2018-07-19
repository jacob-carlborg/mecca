module mecca.platform.os.package;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

version (linux)
    public import mecca.platform.os.linux;
else
    static assert("platform not supported");
