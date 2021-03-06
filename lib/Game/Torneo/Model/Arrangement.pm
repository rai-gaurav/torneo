package Game::Torneo::Model::Arrangement;
use 5.024;
use strictures 2;
use experimental qw< postderef signatures >;
no warnings qw< experimental::postderef experimental::signatures >;
use Math::GF;
use Ouch ':trytiny_var';
use Scalar::Util 'blessed';
use Game::Torneo::Model::Torneo;
use Game::Torneo::Model::Round;
use Game::Torneo::Model::Match;
use Game::Torneo::Model::Participant;
use Game::Torneo::Model::Util 'args';

use Exporter 'import';
our @EXPORT_OK = qw< create >;

sub _sort_for_premium ($ps, $premium) {
   my @ps    = $ps->@*;
   my @newps = (undef) x scalar @ps;

   # first sweep - cover needed premium slots
   my @premium = $premium->@*;
   my @later;
   while (@premium && @ps) {
      my $p = shift @ps;
      if ($p->is_premium) {
         my $i = shift(@premium) - 1;    # off-by-one correction
         $newps[$i] = $p;
      }
      else {
         push @later, $p;
      }
   } ## end while (@premium && @ps)

   ouch 400, 'not enough premium participants'
     if scalar @premium;                 # could not cover them all!

   push @ps, @later;    # put unallocated participants back together
   return map { defined $_ ? $_ : shift @ps } @newps;
} ## end sub _sort_for_premium

sub _participants_array_to_hash_by_id ($aref) {
   return {
      map {
         my %args = ref $_ ? $_->%* : (id => $_);
         my $p = Game::Torneo::Model::Participant->new(%args);
         defined(my $id = $p->id)
            or ouch 400, 'missing identifier for participant';
         ($id => $p);
      } ($aref // [])->@*
   };
} ## end sub _participants_array_to_hash_by_id ($aref)

sub _get_n ($n, $participants) {
   return $n if defined $n;
   my $np = $participants->@*;
   return 6 if $np == 42;
   $n = int sqrt scalar $np;
   return $n if $n * $n == $np;    # it's a square
   ouch 400, "unuseable number of participants ($np)";
} ## end sub _get_n

sub create (@args) {
   my $args = args(@args);

   my $n = _get_n($args->@{qw< players_per_match participants >});
   my $t = $n == 6 ? sixtets($args->{sixtet}) : tournament_arrangement($n);

   my $judges = _participants_array_to_hash_by_id($args->{judges});

   my $eps = _participants_array_to_hash_by_id($args->{participants});
   my @ps  = values $eps->%*;
   @ps = _sort_for_premium(\@ps, $t->{premium}) if $args->{premium};

   my $round_id = 0;
   my @rounds   = map {
      my $round_schedule = $_;
      my $match_id       = 0;
      my @matches        = map {
         my $match_schedule = $_;
         my @participants = map {$ps[$_ - 1]->id} $match_schedule->@*;
         Game::Torneo::Model::Match->new(
            id           => ++$match_id,
            participants => \@participants,
         );
      } $round_schedule->@*;
      Game::Torneo::Model::Round->new(
         id      => ++$round_id,
         matches => \@matches
      );
   } $t->{schedule}->@*;
   return Game::Torneo::Model::Torneo->new(
      metadata     => ($args->{metadata} // {}),
      participants => \@ps,
      judges       => $judges,
      rounds       => \@rounds,
   );
} ## end sub create (@args)

sub sixtets ($option) {
   $option //= 'base';
   my $data     = sixtets_data();
   my @schedule = $data->{base_schedule}->@*;
   my %retval   = (n => 6, schedule => \@schedule);
   if ($option eq 'base') {
      $retval{qw< premium >} = $data->{base_premium};
   }
   elsif ($option eq '7ok') {
      push @schedule, $data->{eighth_round_7_players};
      $retval{qw< premium >} = $data->{ext_premium};
   }
   elsif ($option eq 'dup') {
      push @schedule, $data->{eighth_round_duplicates};
      $retval{qw< premium >} = $data->{ext_premium};
   }
   else {
      die "For sixtets, please specify one of 'base', '7ok', or 'dup'\n";
   }
   return \%retval;
} ## end sub sixtets ($option)

sub sort_round ($round) {
   $round->@* = sort { ($a->[0] // -1) <=> ($b->[0] // -1) } $round->@*;
}

sub tournament_arrangement ($n) {
   my $pp_lines = PG2($n);    # start from a Projective Plane

   # get an Affine Plane from it, removing one line and all its points
   # these points will drive the grouping into rounds, because all other
   # lines contain exactly one of them and are non-overlapping
   my $removed = shift $pp_lines->@*;
   my %round_id_for;
   my $round_id = 0;
   $round_id_for{$_} = ++$round_id for $removed->@*;

   # removing a line means that identifiers in other lines might not be
   # properly ordered, re-map them starting from 1
   my %player_id_for;
   my $player_id = 0;
   for my $i (0 .. ($n * $n + $n)) {    # FIXME should I put -1?
      next if $round_id_for{$i};
      $player_id_for{$i} = ++$player_id;
   }

   # now analyze all remaining lines, use the removed identifier to select
   # the round identifier and ditch it on the way
   my %games_for;    # games grouped by round
   my @games_with_1;
   for my $line ($pp_lines->@*) {
      my $round;
      my @game;
      for my $x ($line->@*) {
         if ($round_id_for{$x}) {
            $round = $round_id_for{$x};
         }
         else {
            my $id = $player_id_for{$x};
            push @game, $id;
            push @games_with_1, \@game if $id == 1;
         }
      } ## end for my $x ($line->@*)
      push $games_for{$round}->@*, \@game;
   } ## end for my $line ($pp_lines...)

   my @premium = $games_with_1[0]->@*;
   push @premium, grep { $_ != 1 } $games_with_1[1]->@*;

   my @schedule =
     map { $games_for{$_} } sort { $a <=> $b } keys %games_for;
   sort_round($_) for @schedule;

   return {
      n        => $n,
      schedule => \@schedule,
      premium  => \@premium,
   };
} ## end sub tournament_arrangement ($n)

sub PG2 ($order) {
   my $field = Math::GF->new(order => $order);
   my @elements = $field->all;

   my $zero = $field->additive_neutral;

   my @points;
   for my $i (@elements[0, 1]) {
      for my $j ($i == $zero ? @elements[0, 1] : @elements) {
         for my $k (
            (($i == $zero) && ($j == $zero)) ? $elements[1] : @elements)
         {
            push @points, [$i, $j, $k];
         }
      } ## end for my $j ($i == $zero ...)
   } ## end for my $i (@elements[0,...])

   my @lines = map { [] } 1 .. scalar(@points);
   for my $li (0 .. $#points) {
      my $L = $points[$li];
      for my $pi ($li .. $#points) {
         last if scalar(@{$lines[$li]}) == $order + 1;
         my $sum = $zero;
         $sum = $sum + $L->[$_] * $points[$pi][$_] for 0 .. 2;
         next if $sum != $zero;
         push @{$lines[$li]}, $pi;
         push @{$lines[$pi]}, $li if $pi != $li;
      } ## end for my $pi ($li .. $#points)
   } ## end for my $li (0 .. $#points)

   return \@lines;
} ## end sub PG2 ($order)

sub sixtets_data {
   my @base_schedule = (
      [
         [1,  2,  3,  4,  5,  6],
         [7,  14, 21, 28, 35, 42],
         [8,  16, 24, 25, 33, 41],
         [9,  18, 20, 29, 31, 40],
         [10, 13, 23, 26, 36, 39],
         [11, 15, 19, 30, 34, 38],
         [12, 17, 22, 27, 32, 37],
      ],
      [
         [1, 18, 23, 28, 33, 38],
         [2, 17, 21, 25, 36, 40],
         [3, 16, 19, 29, 32, 42],
         [4, 15, 24, 26, 35, 37],
         [5, 14, 22, 30, 31, 39],
         [6, 13, 20, 27, 34, 41],
         [7, 8,  9,  10, 11, 12],
      ],
      [
         [1,  10, 21, 30, 32, 41],
         [2,  7,  24, 29, 34, 39],
         [3,  11, 20, 28, 36, 37],
         [4,  8,  23, 27, 31, 42],
         [5,  12, 19, 26, 33, 40],
         [6,  9,  22, 25, 35, 38],
         [13, 14, 15, 16, 17, 18],
      ],
      [
         [1,  9,  17, 26, 34, 42],
         [2,  12, 15, 28, 31, 41],
         [3,  8,  13, 30, 35, 40],
         [4,  11, 18, 25, 32, 39],
         [5,  7,  16, 27, 36, 38],
         [6,  10, 14, 29, 33, 37],
         [19, 20, 21, 22, 23, 24],
      ],
      [
         [1,  12, 16, 20, 35, 39],
         [2,  11, 13, 22, 33, 42],
         [3,  10, 17, 24, 31, 38],
         [4,  9,  14, 19, 36, 41],
         [5,  8,  18, 21, 34, 37],
         [6,  7,  15, 23, 32, 40],
         [25, 26, 27, 28, 29, 30],
      ],
      [
         [1,  11, 14, 24, 27, 40],
         [2,  9,  16, 23, 30, 37],
         [3,  7,  18, 22, 26, 41],
         [4,  12, 13, 21, 29, 38],
         [5,  10, 15, 20, 25, 42],
         [6,  8,  17, 19, 28, 39],
         [31, 32, 33, 34, 35, 36],
      ],
      [
         [1,  8,  15, 22, 29, 36],
         [2,  10, 18, 19, 27, 35],
         [3,  12, 14, 23, 25, 34],
         [4,  7,  17, 20, 30, 33],
         [5,  9,  13, 24, 28, 32],
         [6,  11, 16, 21, 26, 31],
         [37, 38, 39, 40, 41, 42],
      ],
   );

   my @eighth_round_7_players = (
      [1, 7,  13, 19, 25, 31, 37],
      [2, 8,  14, 20, 26, 32, 38],
      [3, 9,  15, 21, 27, 33, 39],
      [4, 10, 16, 22, 28, 34, 40],
      [5, 11, 17, 23, 29, 35, 41],
      [6, 12, 18, 24, 30, 36, 42],
   );

   my @eighth_round_duplicates = (
      [7, 13, 19, 25, 31, 37],
      [8, 14, 20, 26, 32, 38],
      [3, 9,  15, 27, 33, 39],
      [4, 10, 22, 28, 34, 40],
      [5, 11, 17, 23, 35, 41],
      [6, 12, 24, 30, 36, 42],
      [1, 2,  21, 16, 18, 29],
   );

   return {
      base_schedule           => \@base_schedule,
      eighth_round_7_players  => \@eighth_round_7_players,
      eighth_round_duplicates => \@eighth_round_duplicates,
      base_premium            => [1, 7, 13, 19, 25, 31, 37],
      ext_premium             => [1, 3 .. 8, 13, 19, 25, 31, 37],
   };
} ## end sub sixtets_data

1;
