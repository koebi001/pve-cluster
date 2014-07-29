package PVE::Cluster;

use strict;
use warnings;
use POSIX qw(EEXIST);
use File::stat qw();
use Socket;
use Storable qw(dclone);
use IO::File;
use MIME::Base64;
use XML::Parser;
use Digest::SHA;
use Digest::HMAC_SHA1;
use PVE::Tools;
use PVE::INotify;
use PVE::IPCC;
use PVE::SafeSyslog;
use PVE::JSONSchema;
use JSON;
use RRDs;
use Encode;
use base 'Exporter';

our @EXPORT_OK = qw(
cfs_read_file
cfs_write_file
cfs_register_file
cfs_lock_file);

use Data::Dumper; # fixme: remove

# x509 certificate utils

my $basedir = "/etc/pve";
my $authdir = "$basedir/priv";
my $lockdir = "/etc/pve/priv/lock";

my $authprivkeyfn = "$authdir/authkey.key";
my $authpubkeyfn = "$basedir/authkey.pub";
my $pveca_key_fn = "$authdir/pve-root-ca.key";
my $pveca_srl_fn = "$authdir/pve-root-ca.srl";
my $pveca_cert_fn = "$basedir/pve-root-ca.pem";
# this is just a secret accessable by the web browser
# and is used for CSRF prevention
my $pvewww_key_fn = "$basedir/pve-www.key";

# ssh related files
my $ssh_rsa_id_priv = "/root/.ssh/id_rsa";
my $ssh_rsa_id = "/root/.ssh/id_rsa.pub";
my $ssh_host_rsa_id = "/etc/ssh/ssh_host_rsa_key.pub";
my $sshglobalknownhosts = "/etc/ssh/ssh_known_hosts";
my $sshknownhosts = "/etc/pve/priv/known_hosts";
my $sshauthkeys = "/etc/pve/priv/authorized_keys";
my $rootsshauthkeys = "/root/.ssh/authorized_keys";
my $rootsshauthkeysbackup = "${rootsshauthkeys}.org";
my $rootsshconfig = "/root/.ssh/config";

my $observed = {
    'vzdump.cron' => 1,
    'storage.cfg' => 1,
    'datacenter.cfg' => 1,
    'cluster.conf' => 1,
    'cluster.conf.new' => 1,
    'user.cfg' => 1,
    'domains.cfg' => 1,
    'priv/shadow.cfg' => 1,
    '/qemu-server/' => 1,
    '/openvz/' => 1,
};

# only write output if something fails
sub run_silent_cmd {
    my ($cmd) = @_;

    my $outbuf = '';

    my $record_output = sub {
	$outbuf .= shift;
	$outbuf .= "\n";
    };

    eval {
	PVE::Tools::run_command($cmd, outfunc => $record_output, 
				errfunc => $record_output);
    };

    my $err = $@;

    if ($err) {
	print STDERR $outbuf;
	die $err;
    }
}

sub check_cfs_quorum {
    my ($noerr) = @_;

    # note: -w filename always return 1 for root, so wee need
    # to use File::lstat here
    my $st = File::stat::lstat("$basedir/local");
    my $quorate = ($st && (($st->mode & 0200) != 0));

    die "cluster not ready - no quorum?\n" if !$quorate && !$noerr;

    return $quorate;
}

sub check_cfs_is_mounted {
    my ($noerr) = @_;

    my $res = -l "$basedir/local";

    die "pve configuration filesystem not mounted\n"
	if !$res && !$noerr;

    return $res;
}

sub gen_local_dirs {
    my ($nodename) = @_;

    check_cfs_is_mounted();

    my @required_dirs = (
	"$basedir/priv",
	"$basedir/nodes", 
	"$basedir/nodes/$nodename",
	"$basedir/nodes/$nodename/qemu-server",
	"$basedir/nodes/$nodename/openvz",
	"$basedir/nodes/$nodename/priv");
	       
    foreach my $dir (@required_dirs) {
	if (! -d $dir) {
	    mkdir($dir) || $! == EEXIST || die "unable to create directory '$dir' - $!\n";
	}
    }
}

sub gen_auth_key {

    return if -f "$authprivkeyfn";

    check_cfs_is_mounted();

    mkdir $authdir || $! == EEXIST || die "unable to create dir '$authdir' - $!\n";

    my $cmd = "openssl genrsa -out '$authprivkeyfn' 2048";
    run_silent_cmd($cmd);

    $cmd = "openssl rsa -in '$authprivkeyfn' -pubout -out '$authpubkeyfn'";
    run_silent_cmd($cmd)
}

sub gen_pveca_key {

    return if -f $pveca_key_fn;

    eval {
	run_silent_cmd(['openssl', 'genrsa', '-out', $pveca_key_fn, '2048']);
    };

    die "unable to generate pve ca key:\n$@" if $@;
}

sub gen_pveca_cert {

    if (-f $pveca_key_fn && -f $pveca_cert_fn) {
	return 0;
    }

    gen_pveca_key();

    # we try to generate an unique 'subject' to avoid browser problems
    # (reused serial numbers, ..)
    my $nid = (split (/\s/, `md5sum '$pveca_key_fn'`))[0] || time();

    eval {
	run_silent_cmd(['openssl', 'req', '-batch', '-days', '3650', '-new',
			'-x509', '-nodes', '-key',
			$pveca_key_fn, '-out', $pveca_cert_fn, '-subj',
			"/CN=Proxmox Virtual Environment/OU=$nid/O=PVE Cluster Manager CA/"]);
    };

    die "generating pve root certificate failed:\n$@" if $@;

    return 1;
}

sub gen_pve_ssl_key {
    my ($nodename) = @_;

    die "no node name specified" if !$nodename;

    my $pvessl_key_fn = "$basedir/nodes/$nodename/pve-ssl.key";

    return if -f $pvessl_key_fn;

    eval {
	run_silent_cmd(['openssl', 'genrsa', '-out', $pvessl_key_fn, '2048']);
    };

    die "unable to generate pve ssl key for node '$nodename':\n$@" if $@;
}

sub gen_pve_www_key {

    return if -f $pvewww_key_fn;

    eval {
	run_silent_cmd(['openssl', 'genrsa', '-out', $pvewww_key_fn, '2048']);
    };

    die "unable to generate pve www key:\n$@" if $@;
}

sub update_serial {
    my ($serial) = @_;

    PVE::Tools::file_set_contents($pveca_srl_fn, $serial);
}

sub gen_pve_ssl_cert {
    my ($force, $nodename, $ip) = @_;

    die "no node name specified" if !$nodename;
    die "no IP specified" if !$ip;

    my $pvessl_cert_fn = "$basedir/nodes/$nodename/pve-ssl.pem";

    return if !$force && -f $pvessl_cert_fn;

    my $names = "IP:127.0.0.1,DNS:localhost";

    my $rc = PVE::INotify::read_file('resolvconf');

    $names .= ",IP:$ip";
  
    my $fqdn = $nodename;

    $names .= ",DNS:$nodename";

    if ($rc && $rc->{search}) {
	$fqdn = $nodename . "." . $rc->{search};
	$names .= ",DNS:$fqdn";
    }

    my $sslconf = <<__EOD;
RANDFILE = /root/.rnd
extensions = v3_req

[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
string_mask = nombstr

[ req_distinguished_name ]
organizationalUnitName = PVE Cluster Node
organizationName = Proxmox Virtual Environment
commonName = $fqdn

[ v3_req ]
basicConstraints = CA:FALSE
nsCertType = server
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = $names
__EOD

    my $cfgfn = "/tmp/pvesslconf-$$.tmp";
    my $fh = IO::File->new ($cfgfn, "w");
    print $fh $sslconf;
    close ($fh);

    my $reqfn = "/tmp/pvecertreq-$$.tmp";
    unlink $reqfn;

    my $pvessl_key_fn = "$basedir/nodes/$nodename/pve-ssl.key";
    eval {
	run_silent_cmd(['openssl', 'req', '-batch', '-new', '-config', $cfgfn,
			'-key', $pvessl_key_fn, '-out', $reqfn]);
    };

    if (my $err = $@) {
	unlink $reqfn;
	unlink $cfgfn;
	die "unable to generate pve certificate request:\n$err";
    }

    update_serial("0000000000000000") if ! -f $pveca_srl_fn;

    eval {
	run_silent_cmd(['openssl', 'x509', '-req', '-in', $reqfn, '-days', '3650',
			'-out', $pvessl_cert_fn, '-CAkey', $pveca_key_fn,
			'-CA', $pveca_cert_fn, '-CAserial', $pveca_srl_fn,
			'-extfile', $cfgfn]);
    };

    if (my $err = $@) {
	unlink $reqfn;
	unlink $cfgfn;
	die "unable to generate pve ssl certificate:\n$err";
    }

    unlink $cfgfn;
    unlink $reqfn;
}

sub gen_pve_node_files {
    my ($nodename, $ip, $opt_force) = @_;

    gen_local_dirs($nodename);

    gen_auth_key();

    # make sure we have a (cluster wide) secret
    # for CSRFR prevention
    gen_pve_www_key();

    # make sure we have a (per node) private key
    gen_pve_ssl_key($nodename);

    # make sure we have a CA
    my $force = gen_pveca_cert();

    $force = 1 if $opt_force;

    gen_pve_ssl_cert($force, $nodename, $ip);
}

my $vzdump_cron_dummy = <<__EOD;
# cluster wide vzdump cron schedule
# Atomatically generated file - do not edit

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

__EOD

sub gen_pve_vzdump_symlink {

    my $filename = "/etc/pve/vzdump.cron";

    my $link_fn = "/etc/cron.d/vzdump";

    if ((-f $filename) && (! -l $link_fn)) {
	rename($link_fn, "/root/etc_cron_vzdump.org"); # make backup if file exists
	symlink($filename, $link_fn);
    }
}

sub gen_pve_vzdump_files {

    my $filename = "/etc/pve/vzdump.cron";

    PVE::Tools::file_set_contents($filename, $vzdump_cron_dummy)
	if ! -f $filename;

    gen_pve_vzdump_symlink();
};

my $versions = {};
my $vmlist = {};
my $clinfo = {};

my $ipcc_send_rec = sub {
    my ($msgid, $data) = @_;

    my $res = PVE::IPCC::ipcc_send_rec($msgid, $data);

    die "ipcc_send_rec failed: $!\n" if !defined($res) && ($! != 0);

    return $res;
};

my $ipcc_send_rec_json = sub {
    my ($msgid, $data) = @_;

    my $res = PVE::IPCC::ipcc_send_rec($msgid, $data);

    die "ipcc_send_rec failed: $!\n" if !defined($res) && ($! != 0);

    return decode_json($res);
};

my $ipcc_get_config = sub {
    my ($path) = @_;

    my $bindata = pack "Z*", $path;
    my $res = PVE::IPCC::ipcc_send_rec(6, $bindata);
    if (!defined($res)) {
	return undef if ($! != 0);
	return '';
    }

    return $res;
};

my $ipcc_get_status = sub {
    my ($name, $nodename) = @_;

    my $bindata = pack "Z[256]Z[256]", $name, ($nodename || "");
    return PVE::IPCC::ipcc_send_rec(5, $bindata);
};

my $ipcc_update_status = sub {
    my ($name, $data) = @_;

    my $raw = ref($data) ? encode_json($data) : $data;
    # update status
    my $bindata = pack "Z[256]Z*", $name, $raw;

    return &$ipcc_send_rec(4, $bindata);
};

my $ipcc_log = sub {
    my ($priority, $ident, $tag, $msg) = @_;

    my $bindata = pack "CCCZ*Z*Z*", $priority, bytes::length($ident) + 1,
    bytes::length($tag) + 1, $ident, $tag, $msg;

    return &$ipcc_send_rec(7, $bindata);
};

my $ipcc_get_cluster_log = sub {
    my ($user, $max) = @_;

    $max = 0 if !defined($max);

    my $bindata = pack "VVVVZ*", $max, 0, 0, 0, ($user || "");
    return &$ipcc_send_rec(8, $bindata);
};

my $ccache = {};

sub cfs_update {
    eval {
	my $res = &$ipcc_send_rec_json(1);
	#warn "GOT1: " . Dumper($res);
	die "no starttime\n" if !$res->{starttime};

	if (!$res->{starttime} || !$versions->{starttime} ||
	    $res->{starttime} != $versions->{starttime}) {
	    #print "detected changed starttime\n";
	    $vmlist = {};
	    $clinfo = {};
	    $ccache = {};
	}

	$versions = $res;
    };
    my $err = $@;
    if ($err) {
	$versions = {};
	$vmlist = {};
	$clinfo = {};
	$ccache = {};
	warn $err;
    }

    eval {
	if (!$clinfo->{version} || $clinfo->{version} != $versions->{clinfo}) {
	    #warn "detected new clinfo\n";
	    $clinfo = &$ipcc_send_rec_json(2);
	}
    };
    $err = $@;
    if ($err) {
	$clinfo = {};
	warn $err;
    }

    eval {
	if (!$vmlist->{version} || $vmlist->{version} != $versions->{vmlist}) {
	    #warn "detected new vmlist1\n";
	    $vmlist = &$ipcc_send_rec_json(3);
	}
    };
    $err = $@;
    if ($err) {
	$vmlist = {};
	warn $err;
    }
}

sub get_vmlist {
    return $vmlist;
}

sub get_clinfo {
    return $clinfo;
}

sub get_members {
    return $clinfo->{nodelist};
}

sub get_nodelist {

    my $nodelist = $clinfo->{nodelist};

    my $result = [];

    my $nodename = PVE::INotify::nodename();

    if (!$nodelist || !$nodelist->{$nodename}) {
	return [ $nodename ];
    }

    return [ keys %$nodelist ];
}

sub broadcast_tasklist {
    my ($data) = @_;

    eval {
	&$ipcc_update_status("tasklist", $data);
    };

    warn $@ if $@;
}

my $tasklistcache = {};

sub get_tasklist {
    my ($nodename) = @_;

    my $kvstore = $versions->{kvstore} || {};

    my $nodelist = get_nodelist();

    my $res = [];
    foreach my $node (@$nodelist) {
	next if $nodename && ($nodename ne $node);
	eval {
	    my $ver = $kvstore->{$node}->{tasklist} if $kvstore->{$node};
	    my $cd = $tasklistcache->{$node};
	    if (!$cd || !$ver || !$cd->{version} || 
		($cd->{version} != $ver)) {
		my $raw = &$ipcc_get_status("tasklist", $node) || '[]';
		my $data = decode_json($raw);
		push @$res, @$data;
		$cd = $tasklistcache->{$node} = {
		    data => $data,
		    version => $ver,
		};
	    } elsif ($cd && $cd->{data}) {
		push @$res, @{$cd->{data}};
	    }
	};
	my $err = $@;
	syslog('err', $err) if $err;
    }

    return $res;
}

sub broadcast_rrd {
    my ($rrdid, $data) = @_;

    eval {
	&$ipcc_update_status("rrd/$rrdid", $data);
    };
    my $err = $@;

    warn $err if $err;
}

my $last_rrd_dump = 0;
my $last_rrd_data = "";

sub rrd_dump {

    my $ctime = time();

    my $diff = $ctime - $last_rrd_dump;
    if ($diff < 2) {
	return $last_rrd_data;
    }

    my $raw;
    eval {
	$raw = &$ipcc_send_rec(10);
    };
    my $err = $@;

    if ($err) {
	warn $err;
	return {};
    }

    my $res = {};

    if ($raw) {
	while ($raw =~ s/^(.*)\n//) {
	    my ($key, @ela) = split(/:/, $1);
	    next if !$key;
	    next if !(scalar(@ela) > 1);
	    $res->{$key} = \@ela;
	}
    }

    $last_rrd_dump = $ctime;
    $last_rrd_data = $res;

    return $res;
}

sub create_rrd_data {
    my ($rrdname, $timeframe, $cf) = @_;

    my $rrddir = "/var/lib/rrdcached/db";

    my $rrd = "$rrddir/$rrdname";

    my $setup = {
	hour =>  [ 60, 70 ],
	day  =>  [ 60*30, 70 ],
	week =>  [ 60*180, 70 ],
	month => [ 60*720, 70 ],
	year =>  [ 60*10080, 70 ],
    };

    my ($reso, $count) = @{$setup->{$timeframe}};
    my $ctime  = $reso*int(time()/$reso);
    my $req_start = $ctime - $reso*$count;

    $cf = "AVERAGE" if !$cf;

    my @args = (
	"-s" => $req_start,
	"-e" => $ctime - 1,
	"-r" => $reso,
	);

    my $socket = "/var/run/rrdcached.sock";
    push @args, "--daemon" => "unix:$socket" if -S $socket;

    my ($start, $step, $names, $data) = RRDs::fetch($rrd, $cf, @args);

    my $err = RRDs::error;
    die "RRD error: $err\n" if $err;
    
    die "got wrong time resolution ($step != $reso)\n" 
	if $step != $reso;

    my $res = [];
    my $fields = scalar(@$names);
    for my $line (@$data) {
	my $entry = { 'time' => $start };
	$start += $step;
	my $found_undefs;
	for (my $i = 0; $i < $fields; $i++) {
	    my $name = $names->[$i];
	    if (defined(my $val = $line->[$i])) {
		$entry->{$name} = $val;
	    } else {
		# we only add entryies with all data defined
		# extjs chart has problems with undefined values
		$found_undefs = 1;
	    }
	}
	push @$res, $entry if !$found_undefs;
    }

    return $res;
}

sub create_rrd_graph {
    my ($rrdname, $timeframe, $ds, $cf) = @_;

    # Using RRD graph is clumsy - maybe it
    # is better to simply fetch the data, and do all display
    # related things with javascript (new extjs html5 graph library).
	
    my $rrddir = "/var/lib/rrdcached/db";

    my $rrd = "$rrddir/$rrdname";

    my @ids = PVE::Tools::split_list($ds);

    my $ds_txt = join('_', @ids);

    my $filename = "${rrd}_${ds_txt}.png";

    my $setup = {
	hour =>  [ 60, 60 ],
	day  =>  [ 60*30, 70 ],
	week =>  [ 60*180, 70 ],
	month => [ 60*720, 70 ],
	year =>  [ 60*10080, 70 ],
    };

    my ($reso, $count) = @{$setup->{$timeframe}};

    my @args = (
	"--imgformat" => "PNG",
	"--border" => 0,
	"--height" => 200,
	"--width" => 800,
	"--start" => - $reso*$count,
	"--end" => 'now' ,
	"--lower-limit" => 0,
	);

    my $socket = "/var/run/rrdcached.sock";
    push @args, "--daemon" => "unix:$socket" if -S $socket;

    my @coldef = ('#00ddff', '#ff0000');

    $cf = "AVERAGE" if !$cf;

    my $i = 0;
    foreach my $id (@ids) {
	my $col = $coldef[$i++] || die "fixme: no color definition";
	push @args, "DEF:${id}=$rrd:${id}:$cf";
	my $dataid = $id;
	if ($id eq 'cpu' || $id eq 'iowait') {
	    push @args, "CDEF:${id}_per=${id},100,*";
	    $dataid = "${id}_per";
	}
	push @args, "LINE2:${dataid}${col}:${id}";
    }

    push @args, '--full-size-mode';

    # we do not really store data into the file
    my $res = RRDs::graphv('', @args);

    my $err = RRDs::error;
    die "RRD error: $err\n" if $err;

    return { filename => $filename, image => $res->{image} };
}

# a fast way to read files (avoid fuse overhead)
sub get_config {
    my ($path) = @_;

    return &$ipcc_get_config($path);
}

sub get_cluster_log {
    my ($user, $max) = @_;

    return &$ipcc_get_cluster_log($user, $max);
}

my $file_info = {};

sub cfs_register_file {
    my ($filename, $parser, $writer) = @_;

    $observed->{$filename} || die "unknown file '$filename'";

    die "file '$filename' already registered" if $file_info->{$filename};

    $file_info->{$filename} = {
	parser => $parser,
	writer => $writer,
    };
}

my $ccache_read = sub {
    my ($filename, $parser, $version) = @_;

    $ccache->{$filename} = {} if !$ccache->{$filename};

    my $ci = $ccache->{$filename};

    if (!$ci->{version} || !$version || $ci->{version} != $version) {
	# we always call the parser, even when the file does not exists
	# (in that case $data is undef)
	my $data = get_config($filename);
	$ci->{data} = &$parser("/etc/pve/$filename", $data);
	$ci->{version} = $version;
    }

    my $res = ref($ci->{data}) ? dclone($ci->{data}) : $ci->{data};

    return $res;
};

sub cfs_file_version {
    my ($filename) = @_;

    my $version;
    my $infotag;
    if ($filename =~ m!^nodes/[^/]+/(openvz|qemu-server)/(\d+)\.conf$!) {
	my ($type, $vmid) = ($1, $2);
	if ($vmlist && $vmlist->{ids} && $vmlist->{ids}->{$vmid}) {
	    $version = $vmlist->{ids}->{$vmid}->{version};
	}
	$infotag = "/$type/";
    } else {
	$infotag = $filename;
	$version = $versions->{$filename};
    }

    my $info = $file_info->{$infotag} ||
	die "unknown file type '$filename'\n";

    return wantarray ? ($version, $info) : $version;
}

sub cfs_read_file {
    my ($filename) = @_;

    my ($version, $info) = cfs_file_version($filename); 
    my $parser = $info->{parser};

    return &$ccache_read($filename, $parser, $version);
}

sub cfs_write_file {
    my ($filename, $data) = @_;

    my ($version, $info) = cfs_file_version($filename); 

    my $writer = $info->{writer} || die "no writer defined";

    my $fsname = "/etc/pve/$filename";

    my $raw = &$writer($fsname, $data);

    if (my $ci = $ccache->{$filename}) {
	$ci->{version} = undef;
    }

    PVE::Tools::file_set_contents($fsname, $raw);
}

my $cfs_lock = sub {
    my ($lockid, $timeout, $code, @param) = @_;

    my $res;

    # this timeout is for aquire the lock
    $timeout = 10 if !$timeout;

    my $filename = "$lockdir/$lockid";

    my $msg = "can't aquire cfs lock '$lockid'";

    eval {

	mkdir $lockdir;

	if (! -d $lockdir) {
	    die "$msg: pve cluster filesystem not online.\n";
	}

        local $SIG{ALRM} = sub { die "got lock request timeout\n"; };

        alarm ($timeout);

	if (!(mkdir $filename)) {
	    print STDERR "trying to aquire cfs lock '$lockid' ...";
 	    while (1) {
		if (!(mkdir $filename)) {
		    (utime 0, 0, $filename); # cfs unlock request
		} else {
		    print STDERR " OK\n";
		    last;
		}
		sleep(1);
	    }
	}

	# fixed command timeout: cfs locks have a timeout of 120
	# using 60 gives us another 60 seconds to abort the task
	alarm(60);
	local $SIG{ALRM} = sub { die "got lock timeout - aborting command\n"; };

	cfs_update(); # make sure we read latest versions inside code()

	$res = &$code(@param);

	alarm(0);
    };

    my $err = $@;

    alarm(0);

    if ($err && ($err eq "got lock request timeout\n") &&
	!check_cfs_quorum()){
	$err = "$msg: no quorum!\n";
    }	

    if (!$err || $err !~ /^got lock timeout -/) {
	rmdir $filename; # cfs unlock
    }

    if ($err) {
        $@ = $err;
        return undef;
    }

    $@ = undef;

    return $res;
};

sub cfs_lock_file {
    my ($filename, $timeout, $code, @param) = @_;

    my $info = $observed->{$filename} || die "unknown file '$filename'";

    my $lockid = "file-$filename";
    $lockid =~ s/[.\/]/_/g;

    &$cfs_lock($lockid, $timeout, $code, @param);
}

sub cfs_lock_storage {
    my ($storeid, $timeout, $code, @param) = @_;

    my $lockid = "storage-$storeid";

    &$cfs_lock($lockid, $timeout, $code, @param);
}

my $log_levels = {
    "emerg" => 0,
    "alert" => 1,
    "crit" => 2,
    "critical" => 2,
    "err" => 3,
    "error" => 3,
    "warn" => 4,
    "warning" => 4,
    "notice" => 5,
    "info" => 6,
    "debug" => 7,
};

sub log_msg {
   my ($priority, $ident, $msg) = @_;

   if (my $tmp = $log_levels->{$priority}) {
       $priority = $tmp;
   }

   die "need numeric log priority" if $priority !~ /^\d+$/;

   my $tag = PVE::SafeSyslog::tag();

   $msg = "empty message" if !$msg;

   $ident = "" if !$ident;
   $ident = encode("ascii", decode_utf8($ident),
		   sub { sprintf "\\u%04x", shift });

   my $utf8 = decode_utf8($msg);

   my $ascii = encode("ascii", $utf8, sub { sprintf "\\u%04x", shift });

   if ($ident) {
       syslog($priority, "<%s> %s", $ident, $ascii);
   } else {
       syslog($priority, "%s", $ascii);
   }

   eval { &$ipcc_log($priority, $ident, $tag, $ascii); };

   syslog("err", "writing cluster log failed: $@") if $@;
}

sub check_node_exists {
    my ($nodename, $noerr) = @_;

    my $nodelist = $clinfo->{nodelist};
    return 1 if $nodelist && $nodelist->{$nodename};

    return undef if $noerr;

    die "no such cluster node '$nodename'\n";
}

# this is also used to get the IP of the local node
sub remote_node_ip {
    my ($nodename, $noerr) = @_;

    my $nodelist = $clinfo->{nodelist};
    if ($nodelist && $nodelist->{$nodename}) {
	if (my $ip = $nodelist->{$nodename}->{ip}) {
	    return $ip;
	}
    }

    # fallback: try to get IP by other means
    my $packed_ip = gethostbyname($nodename);
    if (defined $packed_ip) {
        my $ip = inet_ntoa($packed_ip);

	if ($ip =~ m/^127\./) {
	    die "hostname lookup failed - got local IP address ($nodename = $ip)\n" if !$noerr;
	    return undef;
	}

	return $ip;
    }

    die "unable to get IP for node '$nodename' - node offline?\n" if !$noerr;

    return undef;
}

# ssh related utility functions

sub ssh_merge_keys {
    # remove duplicate keys in $sshauthkeys
    # ssh-copy-id simply add keys, so the file can grow to large

    my $data = '';
    if (-f $sshauthkeys) {
	$data = PVE::Tools::file_get_contents($sshauthkeys, 128*1024);
	chomp($data);
    }

    my $found_backup;
    if (-f $rootsshauthkeysbackup) {
	$data .= "\n";
	$data .= PVE::Tools::file_get_contents($rootsshauthkeysbackup, 128*1024);
	chomp($data);
	$found_backup = 1;
    }

    # always add ourself
    if (-f $ssh_rsa_id) {
	my $pub = PVE::Tools::file_get_contents($ssh_rsa_id);
	chomp($pub);
	$data .= "\n$pub\n";
    }

    my $newdata = "";
    my $vhash = {};
    my @lines = split(/\n/, $data);
    foreach my $line (@lines) {
	if ($line !~ /^#/ && $line =~ m/(^|\s)ssh-(rsa|dsa)\s+(\S+)\s+\S+$/) {
            next if $vhash->{$3}++;
	}
	$newdata .= "$line\n";
    }

    PVE::Tools::file_set_contents($sshauthkeys, $newdata, 0600);

    if ($found_backup && -l $rootsshauthkeys) {
	# everything went well, so we can remove the backup
	unlink $rootsshauthkeysbackup;
    }
}

sub setup_rootsshconfig {

    # create ssh key if it does not exist
    if (! -f $ssh_rsa_id) {
	mkdir '/root/.ssh/';
	system ("echo|ssh-keygen -t rsa -N '' -b 2048 -f ${ssh_rsa_id_priv}");
    }

    # create ssh config if it does not exist
    if (! -f $rootsshconfig) {
        mkdir '/root/.ssh';
        if (my $fh = IO::File->new($rootsshconfig, O_CREAT|O_WRONLY|O_EXCL, 0640)) {
            # this is the default ciphers list from debian openssl0.9.8 except blowfish is added as prefered
            print $fh "Ciphers blowfish-cbc,aes128-ctr,aes192-ctr,aes256-ctr,arcfour256,arcfour128,aes128-cbc,3des-cbc\n";
            close($fh);
        }
    }
}

sub setup_ssh_keys {

    mkdir $authdir;

    my $import_ok;

    if (! -f $sshauthkeys) {
	my $old;
	if (-f $rootsshauthkeys) {
	    $old = PVE::Tools::file_get_contents($rootsshauthkeys, 128*1024);
	}
	if (my $fh = IO::File->new ($sshauthkeys, O_CREAT|O_WRONLY|O_EXCL, 0400)) {
	    PVE::Tools::safe_print($sshauthkeys, $fh, $old) if $old;
	    close($fh);
	    $import_ok = 1;
	}
    }

    warn "can't create shared ssh key database '$sshauthkeys'\n" 
	if ! -f $sshauthkeys;

    if (-f $rootsshauthkeys && ! -l $rootsshauthkeys) {
	if (!rename($rootsshauthkeys , $rootsshauthkeysbackup)) {
	    warn "rename $rootsshauthkeys failed - $!\n";
	}
    }

    if (! -l $rootsshauthkeys) {
	symlink $sshauthkeys, $rootsshauthkeys;
    }

    if (! -l $rootsshauthkeys) {
	warn "can't create symlink for ssh keys '$rootsshauthkeys' -> '$sshauthkeys'\n";
    } else {
	unlink $rootsshauthkeysbackup if $import_ok;
    }
}

sub ssh_unmerge_known_hosts {
    return if ! -l $sshglobalknownhosts;

    my $old = '';
    $old = PVE::Tools::file_get_contents($sshknownhosts, 128*1024)
	if -f $sshknownhosts;

    PVE::Tools::file_set_contents($sshglobalknownhosts, $old);
}

sub ssh_merge_known_hosts {
    my ($nodename, $ip_address, $createLink) = @_;

    die "no node name specified" if !$nodename;
    die "no ip address specified" if !$ip_address;
   
    mkdir $authdir;

    if (! -f $sshknownhosts) {
	if (my $fh = IO::File->new($sshknownhosts, O_CREAT|O_WRONLY|O_EXCL, 0600)) {
	    close($fh);
	}
    }

    my $old = PVE::Tools::file_get_contents($sshknownhosts, 128*1024); 
    
    my $new = '';
    
    if ((! -l $sshglobalknownhosts) && (-f $sshglobalknownhosts)) {
	$new = PVE::Tools::file_get_contents($sshglobalknownhosts, 128*1024);
    }

    my $hostkey = PVE::Tools::file_get_contents($ssh_host_rsa_id);
    die "can't parse $ssh_rsa_id" if $hostkey !~ m/^(ssh-rsa\s\S+)(\s.*)?$/;
    $hostkey = $1;

    my $data = '';
    my $vhash = {};

    my $found_nodename;
    my $found_local_ip;

    my $merge_line = sub {
	my ($line, $all) = @_;

	if ($line =~ m/^(\S+)\s(ssh-rsa\s\S+)(\s.*)?$/) {
	    my $key = $1;
	    my $rsakey = $2;
	    if (!$vhash->{$key}) {
		$vhash->{$key} = 1;
		if ($key =~ m/\|1\|([^\|\s]+)\|([^\|\s]+)$/) {
		    my $salt = decode_base64($1);
		    my $digest = $2;
		    my $hmac = Digest::HMAC_SHA1->new($salt);
		    $hmac->add($nodename);
		    my $hd = $hmac->b64digest . '=';
		    if ($digest eq $hd) {
			if ($rsakey eq $hostkey) {
			    $found_nodename = 1;
			    $data .= $line;
			}
			return;
		    }
		    $hmac = Digest::HMAC_SHA1->new($salt);
		    $hmac->add($ip_address);
		    $hd = $hmac->b64digest . '=';
		    if ($digest eq $hd) {
			if ($rsakey eq $hostkey) {
			    $found_local_ip = 1;
			    $data .= $line;
			}
			return;
		    }
		}
		$data .= $line;
	    }
	} elsif ($all) {
	    $data .= $line;
	}
    };

    while ($old && $old =~ s/^((.*?)(\n|$))//) {
	my $line = "$2\n";
	next if $line =~ m/^\s*$/; # skip empty lines
	next if $line =~ m/^#/; # skip comments
	&$merge_line($line, 1);
    }

    while ($new && $new =~ s/^((.*?)(\n|$))//) {
	my $line = "$2\n";
	next if $line =~ m/^\s*$/; # skip empty lines
	next if $line =~ m/^#/; # skip comments
	&$merge_line($line);
    }

    my $addIndex = $$;
    my $add_known_hosts_entry  = sub {
	my ($name, $hostkey) = @_;
	$addIndex++;
	my $hmac = Digest::HMAC_SHA1->new("$addIndex" . time());
	my $b64salt = $hmac->b64digest . '=';
	$hmac = Digest::HMAC_SHA1->new(decode_base64($b64salt));
	$hmac->add($name);
	my $digest = $hmac->b64digest . '=';
	$data .= "|1|$b64salt|$digest $hostkey\n";
    };

    if (!$found_nodename || !$found_local_ip) {
	&$add_known_hosts_entry($nodename, $hostkey) if !$found_nodename;
	&$add_known_hosts_entry($ip_address, $hostkey) if !$found_local_ip;
    }

    PVE::Tools::file_set_contents($sshknownhosts, $data);

    return if !$createLink;

    unlink $sshglobalknownhosts;
    symlink $sshknownhosts, $sshglobalknownhosts;
 
    warn "can't create symlink for ssh known hosts '$sshglobalknownhosts' -> '$sshknownhosts'\n" 
	if ! -l $sshglobalknownhosts;

}

my $datacenter_schema = {
    type => "object",
    additionalProperties => 0,
    properties => {
	keyboard => {
	    optional => 1,
	    type => 'string',
	    description => "Default keybord layout for vnc server.",
	    enum => PVE::Tools::kvmkeymaplist(),
	},
	language => {
	    optional => 1,
	    type => 'string',
	    description => "Default GUI language.",
	    enum => [ 'en', 'de' ],
	},
	http_proxy => {
	    optional => 1,
	    type => 'string',
	    description => "Specify external http proxy which is used for downloads (example: 'http://username:password\@host:port/')",
	    pattern => "http://.*",
	},
	migration_unsecure => {
	    optional => 1,
	    type => 'boolean',
	    description => "Migration is secure using SSH tunnel by default. For secure private networks you can disable it to speed up migration.",
	},
	console => {
	    optional => 1,
	    type => 'string',
	    description => "Select the default Console viewer. You can either use the builtin java applet (VNC), an external virt-viewer comtatible application (SPICE), or an HTML5 based viewer (noVNC).",
	    enum => ['applet', 'vv', 'html5'],
	},
    },
};

# make schema accessible from outside (for documentation)
sub get_datacenter_schema { return $datacenter_schema };

sub parse_datacenter_config {
    my ($filename, $raw) = @_;

    return PVE::JSONSchema::parse_config($datacenter_schema, $filename, $raw);
}

sub write_datacenter_config {
    my ($filename, $cfg) = @_;
    
    return PVE::JSONSchema::dump_config($datacenter_schema, $filename, $cfg);
}

cfs_register_file('datacenter.cfg', 
		  \&parse_datacenter_config,  
		  \&write_datacenter_config);

sub parse_cluster_conf {
    my ($filename, $raw) = @_;

    my $conf = {};

    my $digest = Digest::SHA::sha1_hex(defined($raw) ? $raw : '');

    my $createNode = sub {
	my ($expat, $tag, %attrib) = @_;
	$expat->{NodeCount}++;
	return { text => $tag, id => $expat->{NodeCount}, %attrib };
    }; 

    my $handlers = {
	Init => sub {
	    my $expat = shift;
	    $expat->{NodeCount} = 0;
	    $expat->{NodeStack} = [];
	    $expat->{CurNode} = $expat->{Tree} = &$createNode($expat, 'root');
	},
	Final => sub {
	    my $expat = shift;
	    delete $expat->{CurNode};
	    delete $expat->{NodeStack};
	    $expat->{Tree};
	},
	Start => sub {
	    my $expat = shift;
	    my $tag = shift;
	    my $parent = $expat->{CurNode};
	    push @{ $expat->{NodeStack} }, $parent;
	    my $node = &$createNode($expat, $tag, @_);
	    push @{$expat->{CurNode}->{children}}, $node;
	    $expat->{CurNode} = $node;
	},
	End => sub {
	    my $expat = shift;
	    my $tag = shift;
	    my $node = pop @{ $expat->{NodeStack} };
	    $expat->{CurNode} = $node;
	},
    };
 
    if ($raw) {
	my $parser = new XML::Parser(Handlers => $handlers);
	$conf = $parser->parse($raw);
    }

    $conf->{digest} = $digest;

    return $conf;
}

sub cluster_conf_version {
    my ($conf, $noerr) = @_;

    if ($conf && $conf->{children} && $conf->{children}->[0]) {
	my $cluster = $conf->{children}->[0];
	if ($cluster && ($cluster->{text} eq 'cluster') && 
	    $cluster->{config_version}) {
	    if (my $version = int($cluster->{config_version})) {
		return wantarray ? ($version, $cluster) : $version;
	    }
	}
    }

    return undef if $noerr;

    die "no cluster config - unable to read version\n";
}

sub cluster_conf_lookup_cluster_section {
    my ($conf, $noerr) = @_;

    my ($version, $cluster) = cluster_conf_version($conf, $noerr);

    return $cluster;
}

sub cluster_conf_lookup_rm_section {
    my ($conf, $create, $noerr) = @_;

    my $cluster = cluster_conf_lookup_cluster_section($conf, $noerr);
    return undef if !$cluster;

    my $rmsec;
    foreach my $child (@{$cluster->{children}}) {
	if ($child->{text} eq 'rm') {
	    $rmsec = $child;
	}
    }
    if (!$rmsec) {
	if (!$create) {
	    return undef if $noerr;
	    die "no resource manager section\n";
	}
	$rmsec = { text => 'rm' };
	push @{$cluster->{children}}, $rmsec;
    }

    return $rmsec;
}

sub cluster_conf_lookup_pvevm {
    my ($conf, $create, $vmid, $noerr) = @_;

    my $rmsec = cluster_conf_lookup_rm_section($conf, $create, $noerr);
    return undef if !$rmsec;

    my $vmref;
    foreach my $child (@{$rmsec->{children}}) {
	if ($child->{text} eq 'pvevm' && $child->{vmid} eq $vmid) {
	    $vmref = $child;
	}
    }

    if (!$vmref) {
	if (!$create) {
	    return undef if $noerr;
	    die "unable to find service 'pvevm:$vmid'\n";
	}
	$vmref = { text => 'pvevm', vmid => $vmid };
	push @{$rmsec->{children}}, $vmref;
    } elsif ($create) {
	return undef if $noerr;
	die "unable to create service 'pvevm:$vmid' - already exists\n";
    }

    return $vmref;
}

sub xml_escape_attrib {
    my ($data) = @_;

    return '' if !defined($data);

    $data =~ s/&/&amp;/sg;
    $data =~ s/</&lt;/sg;
    $data =~ s/>/&gt;/sg;
    $data =~ s/"/&quot;/sg;

    return $data;
}

sub __cluster_conf_dump_node {
    my ($node, $indend) = @_;

    my $xml = '';

    $indend = '' if !defined($indend);

    my $attribs = '';

    foreach my $key (sort keys %$node) {
	my $value = $node->{$key};
	next if $key eq 'id' || $key eq 'text' || $key eq 'children';
	$attribs .= " $key=\"" .  xml_escape_attrib($value) . "\"";
    }
    
    my $children = $node->{children};

    if ($children && scalar(@$children)) {
	$xml .= "$indend<$node->{text}$attribs>\n";
	my $childindend = "$indend  ";
	foreach my $child (@$children) {
	    $xml .= __cluster_conf_dump_node($child, $childindend);
	}
	$xml .= "$indend</$node->{text}>\n";
    } else { 
	$xml .= "$indend<$node->{text}$attribs/>\n";
    }

    return $xml;
}

sub write_cluster_conf {
    my ($filename, $cfg) = @_;

    my $version = cluster_conf_version($cfg);
 
    my $res = "<?xml version=\"1.0\"?>\n";

    $res .= __cluster_conf_dump_node($cfg->{children}->[0]);

    return $res;
}

# read only - use "rename cluster.conf.new cluster.conf" to write
PVE::Cluster::cfs_register_file('cluster.conf', \&parse_cluster_conf);
# this is read/write
PVE::Cluster::cfs_register_file('cluster.conf.new', \&parse_cluster_conf, 
				\&write_cluster_conf);
