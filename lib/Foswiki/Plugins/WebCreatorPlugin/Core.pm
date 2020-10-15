# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# WebCreatorPlugin is Copyright (C) 2019-2020 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::WebCreatorPlugin::Core;

use strict;
use warnings;

use Foswiki::Func ();
use Foswiki::Form ();
use Foswiki::Plugins ();
use Error qw(:try);

use constant TRACE => 0; # toggle me

sub new {
  my $class = shift;
  my $session = shift || $Foswiki::Plugins::SESSION;

  my $this = bless({
    session => $session,
    @_
  }, $class);

  return $this;
}

sub DESTROY {
  my $this = shift;

  undef $this->{session};
}

# params:
# - templateweb
# - parentweb
# - newweb
# - user
# - dry
# - UPPERCASE webPrefs
sub jsonRpcCreate {
  my ($this, $request) = @_;

  _writeDebug("called jsonRpcCreate");

  my $wikiName = Foswiki::Func::getWikiName();
  _writeDebug("wikiName=$wikiName");

  my $dry = Foswiki::Func::isTrue($request->param("dry"), 0);

  my $templateWeb = $request->param("templateweb") || "_default";
  _writeDebug("templateWeb=$templateWeb");

  throw Error::Simple("template web does not exist") unless Foswiki::Func::webExists($templateWeb);
  throw Error::Simple("access denied to template web") unless Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, undef, $templateWeb);

  my $newWeb = $request->param("newweb");
  throw Error::Simple("no newweb parameter specified") unless $newWeb;

  my $parentWeb = $request->param("parentweb") || '';

  if ($parentWeb) {
    throw Error::Simple("parent web does not exist") unless Foswiki::Func::webExists($parentWeb);
    #my ( $type, $user, $text, $inTopic, $inWeb, $meta ) = @_;
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

  throw Error::Simple("invalid web name") unless Foswiki::Func::isValidWebName($newWeb);

  my $overwrite = Foswiki::Func::isTrue($request->param("overwrite"), 0);
  _writeDebug("overwrite=$overwrite");

  throw Error::Simple("web already exists") if !$overwrite && Foswiki::Func::webExists($newWeb);

  # collect web preferences
  my $webPrefs = {
    ALLOWWEBVIEW => $wikiName,
    ALLOWWEBCHANGE => $wikiName,
    ALLOWWEBRENAME => $wikiName,
    ALLOWTOPICCHANGE => $wikiName,
    ALLOWTOPICRENAME => $wikiName,
  };

  foreach my $key (keys %{$request->params()}) {
    next unless $key =~ /^[A-Z][A-Z_]*$/;
    my $v = $request->param($key);
    $webPrefs->{$key} = $v;
  }

  if (TRACE) {
    _writeDebug("webPref: $_=$webPrefs->{$_}") foreach sort keys %$webPrefs;
  }

  my $params = {
    source => $templateWeb, 
    target => $newWeb, 
    prefs => $webPrefs, 
    dry => $dry
  };

  # call index topic handlers
  $this->callBeforeCreaterWebHandler($params);
  $this->copyWeb($params);
  $this->callAfterCreaterWebHandler($params);

  # return url of newly create web
  return {
    redirect => Foswiki::Func::getScriptUrl($newWeb, $Foswiki::cfg{HomeTopicName}, "view")
  };
}

# {
#   source => ...,
#   target => ...,
#   prefs => ...,
#   dry => ...
# }
sub copyWeb {
  my ($this, $params) = @_;

  $params->{source} =~ s/\./\//g;
  $params->{target} =~ s/\./\//g;

  _writeDebug("called copyWeb($params->{source}, $params->{target})");

  my $sourceObj = Foswiki::Meta->new($this->{session}, $params->{source});
  my $targetObj = Foswiki::Meta->new($this->{session}, $params->{target});

  unless (Foswiki::Func::topicExists($params->{target}, $Foswiki::cfg{WebPrefsTopicName})) {
    my $obj = $targetObj->new($this->{session}, $params->{target}, $Foswiki::cfg{WebPrefsTopicName}, "");
    $obj->save() unless $params->{dry};
  }

  my $it = $sourceObj->eachTopic();

  while ($it->hasNext()) {
    my $topic = $it->next();
    my $obj = Foswiki::Meta->load($this->{session}, $params->{source}, $topic);

    _writeDebug("copying topic $params->{source}.$topic to $params->{target}.$topic");

    # open attachment file handles
    my %attfh;
    foreach my $sfa ($obj->find('FILEATTACHMENT')) {
      my $fh = $obj->openAttachment($sfa->{name}, '<');
      _writeDebug("copying attachment $sfa->{name}");

      $attfh{$sfa->{name}} = {
        fh => $fh,
        date => $sfa->{date},
        user => $sfa->{user} || $this->{session}{user},
        comment => $sfa->{comment}
      };
    }

    # store other meta in WebHome
    $this->populateMetaFromQuery($obj) if $topic eq $Foswiki::cfg{HomeTopicName} && !$params->{dry};

    $obj->save( # vs saveAs
      web => $params->{target},
      topic => $topic,
      forcenewrevision => 1
    ) unless $params->{dry};

    # copy file attachments
    while (my ($fa, $sfa) = each %attfh) {

      my $arev;
      $arev = $this->{session}{store}->saveAttachment(
        $obj, $fa,
        $sfa->{fh},
        $sfa->{user},
        {
          forcedate => $sfa->{date},
          minor => 1,
          comment => $sfa->{comment}
        }
      ) unless $params->{dry};

      close($sfa->{fh});
    }
  }

  # patch WebPreferences
  if ($params->{prefs}) {
    my $prefsTopicObject = Foswiki::Meta->load($this->{session}, $params->{target}, $Foswiki::cfg{WebPrefsTopicName});
    my $text = $prefsTopicObject->text();
    unless (defined $text) {
      (undef, $text) = Foswiki::Func::readTopic($params->{source}, $Foswiki::cfg{WebPrefsTopicName});
    }

    my @bottomText = ();
    foreach my $key (keys %{$params->{prefs}}) {
      if (defined($params->{prefs}->{$key})) {
        if ($text =~ s/^((?:\t|   )+\*\s+)#?Set\s+$key\s*=.*?$/$1Set $key = $params->{prefs}->{$key}/gm) {
          _writeDebug("patching $key");
          # found in template
        } else {
          _writeDebug("appending $key");
          # not found, append it
          push @bottomText, "   * Set $key = $params->{prefs}->{$key}";
        }
      }
    }
    if (@bottomText) {
      $text .= "\n" unless $text =~ /\n$/;
      $text .= "\n---++ More Settings\n";
      $text .= join("\n", @bottomText)."\n";
    }

    #_writeDebug("WebPreferences:\n$text");
    $prefsTopicObject->text($text);
    $prefsTopicObject->save() unless $params->{dry};
  }

  # update dbcache
  if (Foswiki::Func::getContext()->{DBCachePluginEnabled}) {
    _writeDebug("updating dbcache");
    require Foswiki::Plugins::DBCachePlugin;
    Foswiki::Plugins::DBCachePlugin::getDB($params->{target}, 2) unless $params->{dry};
  }
}

sub populateMetaFromQuery {
  my ($this, $obj) = @_;

  _writeDebug("called populateMetaFromQuery for ".$obj->topic);

  my $request = Foswiki::Func::getRequestObject();

  my $formName = $obj->getFormName();
  my ($web, $topic) = Foswiki::Func::normalizeWebTopicName($obj->web, $formName);
  my $formDef = new Foswiki::Form($this->{session}, $web, $topic);

  $formDef->getFieldValuesFromQuery($request, $obj);
}

sub callBeforeCreaterWebHandler {
  my ($this, $params) = @_;

  _writeDebug("calling before create web handler");
  my %seen;
  foreach my $sub (@Foswiki::Plugins::WebCreatorPlugin::beforeCreateWebHandler) {
    next if $seen{$sub};
    &$sub($this, $params);
    $seen{$sub} = 1;
  }
}

sub callAfterCreaterWebHandler {
  my ($this, $params) = @_;

  _writeDebug("calling after create web handler");
  my %seen;
  foreach my $sub (@Foswiki::Plugins::WebCreatorPlugin::afterCreateWebHandler) {
    next if $seen{$sub};
    &$sub($this, $params);
    $seen{$sub} = 1;
  }
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "WebCreatorPlugin::Core - $_[0]\n";
}

1;
