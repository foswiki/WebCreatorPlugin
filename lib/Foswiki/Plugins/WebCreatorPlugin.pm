# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# WebCreatorPlugin is Copyright (C) 2019-2022 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::WebCreatorPlugin;

use strict;
use warnings;

use Foswiki::Func ();
use Foswiki::Contrib::JsonRpcContrib ();

our $VERSION = '2.00';
our $RELEASE = '05 May 2022';
our $SHORTDESCRIPTION = 'Flexible way to create new webs';
our $NO_PREFS_IN_TOPIC = 1;
our $core;

our @beforeCreateWebHandler = ();
our @afterCreateWebHandler = ();

sub initPlugin {

  Foswiki::Contrib::JsonRpcContrib::registerMethod("WebCreatorPlugin", "create", sub {
    return getCore(shift)->jsonRpcCreate(@_);
  });

  return 1;
}

sub registerBeforeCreateWebHandler {
  push @beforeCreateWebHandler, shift;
}
sub registerAfterCreateWebHandler {
  push @afterCreateWebHandler, shift;
}

sub getCore {
  unless (defined $core) {
    require Foswiki::Plugins::WebCreatorPlugin::Core;
    $core = Foswiki::Plugins::WebCreatorPlugin::Core->new(shift);
  }
  return $core;
}

sub finishPlugin {
  undef $core;
  @beforeCreateWebHandler = ();
  @afterCreateWebHandler = ();
}

1;
