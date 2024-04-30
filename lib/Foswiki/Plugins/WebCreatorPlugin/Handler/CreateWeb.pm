# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# WebCreatorPlugin is Copyright (C) 2022 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::WebCreatorPlugin::Handler::CreateWeb;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Plugins::WebCreatorPlugin ();

use constant TRACE => 0;    # toggle me
#use Data::Dump qw(dump);

sub handle {
  my ($command, $state) = @_;

  _writeDebug("called handle()");

  my $params = $command->getParams();
  my $wikiName = Foswiki::Func::getWikiName();

  my $dry = Foswiki::Func::isTrue($params->{dry}, 0);
  _writeDebug("dry run") if $dry;

  my $templateWeb = $params->{templateweb} || $params->{template} || "_default";
  _writeDebug("templateWeb=$templateWeb");

  throw Error::Simple("template web does not exist") unless Foswiki::Func::webExists($templateWeb);
  throw Error::Simple("access denied to template web") unless Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, undef, $templateWeb);

  my $newWeb = $params->{_DEFAULT} || $params->{newweb};
  throw Error::Simple("no newweb parameter specified") unless $newWeb;

  my $parentWeb = $params->{parentweb} || $params->{parent} || '';

  if ($parentWeb) {
    throw Error::Simple("parent web does not exist") unless Foswiki::Func::webExists($parentWeb);
    throw Error::Simple("access denied to parent web") unless Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, undef, $parentWeb);

    $newWeb = "$parentWeb.$newWeb";
  }

  _writeDebug("newWeb=$newWeb");

  # expand autoinc
  if ($newWeb =~ /^(.*)AUTOINC(\d+)(.*)$/) {
    my $pre = $1 // '';
    my $start = $2;
    my $post = $3 // '';
    my $pad = length($start);

    foreach my $web (Foswiki::Func::getListOfWebs()) {
      $web =~ s/\//./g;
      next unless $web =~ /^\Q$pre\E(\d+)\Q$post\E$/;
      $start = $1 + 1 if $1 >= $start;
    }

    $newWeb = sprintf("$pre%0${pad}d$post", $start);
  }

  throw Error::Simple("invalid web name") unless Foswiki::Func::isValidWebName($newWeb, 1);

  my $overwrite = Foswiki::Func::isTrue($params->{overwrite}, 0);
  _writeDebug("overwrite=$overwrite");

  throw Error::Simple("web already exists") if !$overwrite && Foswiki::Func::webExists($newWeb);

  # collect web preferences
  my $webPrefs = {
    ALLOWWEBVIEW => $wikiName,
    ALLOWWEBCHANGE => $wikiName,
    ALLOWWEBRENAME => $wikiName,
    ALLOWTOPICCHANGE => $wikiName
  };

  foreach my $key (keys %$params) {
    next unless $key =~ /^[A-Z][A-Z_]*$/;
    my $v = $params->{$key};
    $webPrefs->{$key} = $v;
  }

  $params->{source} = $templateWeb;
  $params->{target} = $newWeb;
  $params->{prefs} = $webPrefs;
  $params->{dry} = $dry;

  #_writeDebug("params=".dump($params));

  my $error;

  my $core = Foswiki::Plugins::WebCreatorPlugin::getCore();

  # call index topic handlers
  $core->callBeforeCreaterWebHandler($params);

  try {
    $core->copyWeb($params);
  } catch Error with {
    $error = shift;
  };

  throw Error::Simple($error) if $error;

  $core->callAfterCreaterWebHandler($params);

  if (Foswiki::Func::isTrue($params->{redirect}, 0)) {
    my $url = Foswiki::Func::getScriptUrlPath($newWeb, $Foswiki::cfg{HomeTopicName}, "view");
    _writeDebug("... redirecting to $url");
    $state->getCore->redirectUrl($url);
  }

  _writeDebug("done create web");
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "WebCreatorPlugin::CreateWeb - $_[0]\n";
}

1;
