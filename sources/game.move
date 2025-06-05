module poker::game;

use poker::debug::print_debug;
use std::option::{some, none};
use sui::balance::Balance;
use sui::coin::Coin;
use sui::event::emit;
use sui::random::{Random, new_generator};
use sui::sui::SUI;

// Constants for game configuration
const MIN_PLAYERS: u64 = 2;
const MAX_PLAYERS: u64 = 8;
const CARDS_PER_PLAYER: u64 = 2;
const SEED_LENGTH: u64 = 32;
const MIN_BUY_IN: u64 = 10_000_000; // 0.01 SUI

// ===== Game Constants =====

// Error codes
const EInvalidGameState: u64 = 0x000B; // Internal errors
const EGameInProgress: u64 = 0x0000;
const EGameNotStarted: u64 = 0x0001;
const EEInsufficientPlayer: u64 = 0x0002;
const EInsufficientBuyIn: u64 = 0x0003;
const EBuyInMismatch: u64 = 0x0004;
const EInvalidPlayer: u64 = 0x0005;
const EInvalidAction: u64 = 0x0006;
const EInvalidAmount: u64 = 0x0007;
const EAlreadyJoined: u64 = 0x0008;
const ESeatOccupied: u64 = 0x0009;
const EInvalidSeat: u64 = 0x000A;

// Player actions
public enum PlayerAction has copy, drop {
  Fold,
  Check,
  Call { amount: u64, all_in: bool },
  BetOrRaise { amount: u64, all_in: bool },
}

// Game states
public enum GameStage has copy, drop, store {
  Waiting,
  PreFlop,
  Flop,
  Turn,
  River,
  Showdown,
  Ended,
}

public enum PlayerState has copy, drop, store {
  Waiting,
  Active,
  Folded,
  Checked,
  Called,
  RaisedOrBetted,
  AllIn,
}

// Hand ranking constants
const HAND_HIGH_CARD: u8 = 0;
const HAND_ONE_PAIR: u8 = 1;
const HAND_TWO_PAIR: u8 = 2;
const HAND_THREE_OF_A_KIND: u8 = 3;
const HAND_STRAIGHT: u8 = 4;
const HAND_FLUSH: u8 = 5;
const HAND_FULL_HOUSE: u8 = 6;
const HAND_FOUR_OF_A_KIND: u8 = 7;
const HAND_STRAIGHT_FLUSH: u8 = 8;
const HAND_ROYAL_FLUSH: u8 = 9;

// ===== Game Structs =====

/// Card representation
///
/// - Suit: 0 = Hearts, 1 = Diamonds, 2 = Clubs, 3 = Spades
/// - Value: 2-14 (2-10, Jack=11, Queen=12, King=13, Ace=14)
public struct Card has copy, drop, store {
  suit: u8,
  value: u8,
}

// Hand evaluation result
public struct HandRank has copy, drop, store {
  /// Type of hand (0-9)
  hand_type: u8,
  /// Primary value for comparison (e.g., pair value, high card)
  primary_value: u8,
  /// Secondary value (e.g., kicker for pair, second pair for two pair)
  secondary_value: u8,
  /// Additional kickers for tie-breaking
  kickers: vector<u8>,
}

/// Side pot information for all-in scenarios
public struct SidePot has copy, drop, store {
  amount: u64,
  eligible_players: vector<address>, // Player addresses eligible for this pot
  winners: vector<address>, // Players who won this side pot
}

/// Player in the game
public struct Player has copy, drop, store {
  /// Player's wallet address
  addr: address,
  /// Cards held by the player
  cards: vector<Card>,
  /// Player's current balance in the game
  balance: u64,
  /// Current bet amount for this player in the current round. Should be calculated right after the player acts.
  current_bet: u64,
  /// Total amount contributed by the player in the current hand (including blinds and bets). Used for side pot calculations.
  total_contributed: u64,
  /// Player's state in the game
  state: PlayerState,
}

/// Showdown participant
public struct Participant has copy, drop, store {
  /// Player's address
  addr: address,
  /// Cards held by the player
  cards: vector<Card>,
  /// Hand rank of the player's hand
  hand_rank: HandRank,
}

/// Main game object
public struct PokerGame has key {
  id: UID,
  // ================ Game State ================
  /// Player seats at the table, indexed by seat number
  seats: vector<Option<Player>>,
  /// Deck of cards for the game
  deck: vector<Card>,
  /// Community cards dealt on the table
  community_cards: vector<Card>,
  /// Main pot amount for current hand
  pot: u64,
  /// Side pots for all-in scenarios
  side_pots: vector<SidePot>,
  /// Current bet amount of the round
  current_bet: u64,
  /// Current game stage
  stage: GameStage,
  /// Current game hand dealer position (seat number)
  dealer_position: u64,
  /// Last player position (seat number) that raised the bet in this round
  last_raise_position: Option<u64>,
  /// Addresses of players who won the main pot of current hand
  winners: vector<address>,
  // ================ Game Configuration ================
  /// Buy-in amount for the game
  buy_in: u64,
  /// Minimum bet amount (5% of buy-in)
  min_bet: u64,
  // ================ Game Metadata ================
  /// Address of the game owner (creator)
  owner: address,
  /// Number of hands played in this game
  hand_played: u64,
  /// Treasury balance that holds all players funds
  treasury: Balance<SUI>,
}

// ===== Events =====

public struct GameCreated has copy, drop { game_id: ID, buy_in: u64 }

public struct PlayerJoined has copy, drop { game_id: ID, player: address }

public struct GameStarted has copy, drop { game_id: ID, num_players: u64 }

public struct PlayerMoved has copy, drop {
  game_id: ID,
  player: address,
  action: PlayerAction,
}

public struct RoundChanged has copy, drop { game_id: ID, new_state: GameStage }

public struct GameEnded has copy, drop { game_id: ID }

public struct PlayerWithdrawn has copy, drop {
  game_id: ID,
  player: address,
  balance: u64,
}

// ===== Public Game Actions =====

/// Create a new poker game
public entry fun create(payment: Coin<SUI>, ctx: &mut TxContext): ID {
  let id = object::new(ctx);
  let game_id = id.to_inner();
  let owner_addr = ctx.sender();

  // Calculate derived values from buy_in
  let buy_in = payment.value();
  let min_bet = buy_in / 20; // 5% of buy_in

  // Check buy-in amount for creator
  assert!(buy_in >= MIN_BUY_IN, EInsufficientBuyIn);

  let mut game = PokerGame {
    id,
    // ===== Game State =====
    seats: vector[],
    deck: vector[],
    community_cards: vector[],
    side_pots: vector[],
    pot: 0,
    current_bet: 0,
    stage: GameStage::Waiting,
    dealer_position: 0,
    last_raise_position: none(),
    winners: vector[],
    // ===== Game Configuration =====
    buy_in,
    min_bet,
    // ===== Game Metadata =====
    owner: owner_addr,
    hand_played: 0,
    treasury: payment.into_balance(), // Initialize treasury with creator's payment
  };
  MAX_PLAYERS.do!(|_| game.seats.push_back(none())); // Initialize seats with None
  game.sit_to_seat(0, owner_addr, buy_in); // Owner sits at seat 0 with buy-in
  emit(GameCreated { game_id, buy_in });
  emit(PlayerJoined { game_id, player: owner_addr });

  transfer::share_object(game);

  game_id
}

/// Join an existing poker game
public entry fun join(
  game: &mut PokerGame,
  payment: Coin<SUI>,
  seat: u64,
  ctx: &mut TxContext,
) {
  let player_addr = ctx.sender();
  assert!(game.stage == GameStage::Waiting, EGameInProgress);
  assert!(payment.value() == game.buy_in, EBuyInMismatch);
  assert!(
    !game.seats.any!(|p| p.is_some_and!(|s| s.addr == player_addr)),
    EAlreadyJoined,
  );
  game.sit_to_seat(seat, player_addr, payment.value());
  game.treasury.join(payment.into_balance()); // Add payment to treasury
  emit(PlayerJoined { game_id: game.id.to_inner(), player: player_addr });
}

/// End the poker game and refund all players balances
public entry fun end(game: PokerGame, ctx: &mut TxContext) {
  assert!(ctx.sender() == game.owner, EInvalidPlayer); // Only owner can cancel the game
  assert!(
    game.stage == GameStage::Waiting || game.stage == GameStage::Ended,
    EGameInProgress,
  ); // Game must be in waiting stage or ended to cancel

  let PokerGame { id, mut treasury, mut seats, .. } = game;
  // Refund each player's balance
  seats.do_mut!(|seat| {
    if (seat.is_none()) return; // Skip empty seats
    seat.do_mut!(|p| {
      let funds = treasury.split(p.balance);
      p.balance = 0; // Reset player balance
      transfer::public_transfer(funds.into_coin(ctx), p.addr);
    });
  });
  treasury.destroy_zero(); // Destroy treasury, it should be empty now
  emit(GameEnded { game_id: id.to_inner() });
  id.delete(); // Delete the game
}

/// Start the poker game if we have enough players
entry fun start(game: &mut PokerGame, r: &Random, ctx: &mut TxContext) {
  let seed = generate_seed(r, ctx);
  start_with_seed(game, seed, ctx)
}

fun start_with_seed(game: &mut PokerGame, seed: vector<u8>, ctx: &TxContext) {
  let player_count = game.seats.count!(|s| s.is_some());

  assert!(seed.length() == SEED_LENGTH, EInvalidGameState);
  assert!(player_count >= MIN_PLAYERS, EEInsufficientPlayer);
  assert!(
    game.stage == GameStage::Waiting || game.stage == GameStage::Ended,
    EGameInProgress,
  );
  assert!(ctx.sender() == game.owner, EInvalidPlayer); // Only owner can start the game (should remove?)

  game.set_dealer_position();
  game.set_blinds();
  game.initialize_deck();
  game.shuffle_deck(seed);
  game.deal_cards();

  let active_pos = game.seats.walk_occupied_seat(game.dealer_position, 3); // First player to act is the player after the big blind
  game.seats.do_mut!(|s| s.do_mut!(|p| p.state = PlayerState::Waiting)); // Set all players to waiting state
  game.seats[active_pos].do_mut!(|p| p.state = PlayerState::Active); // Set them to active
  game.last_raise_position = none(); // Reset last raise position
  game.stage = GameStage::PreFlop; // Advance to pre-flop stage

  print_debug(b"🚀 Game started with seed: ", &seed);
  print_debug(b"» Player count: ", &game.seats.count!(|s| s.is_some()));
  print_debug(b"» Dealer position: ", &game.dealer_position);
  print_debug(b"» Active position: ", &active_pos);
  print_debug(b"» Min bet: ", &game.min_bet);
  print_debug(b"💰 Pot", &game.pot);
  print_debug(b"➡️ Active Player:", &game.seats[active_pos].borrow().addr);

  // Emit event
  emit(GameStarted { game_id: game.id.to_inner(), num_players: player_count });
}

// ===== Public Player Actions =====

/// Withdraw from the game
entry fun withdraw(game: &mut PokerGame, ctx: &mut TxContext) {
  assert!(
    game.stage == GameStage::Ended || game.stage == GameStage::Waiting, // Game must be over or waiting
    EGameInProgress,
  );
  let player = ctx.sender();
  let seat_index = game.find_seat_index(player);
  let seat = game.seats.borrow_mut(seat_index);
  let p = seat.borrow_mut();
  let balance = p.balance;
  if (balance > 0) {
    p.balance = 0; // Reset player balance to 0
    let winnings = game.treasury.split(balance).into_coin(ctx);
    transfer::public_transfer(winnings, player); // Transfer winnings to player
  };
  seat.extract(); // Remove player from game, leaving an empty seat
  emit(PlayerWithdrawn { game_id: game.id.to_inner(), player, balance });
}

// Player action: fold
public entry fun fold(game: &mut PokerGame, ctx: &mut TxContext) {
  player_act(game, ctx.sender(), &mut PlayerAction::Fold);
}

// Player action: check
public entry fun check(game: &mut PokerGame, ctx: &mut TxContext) {
  player_act(game, ctx.sender(), &mut PlayerAction::Check);
}

// Player action: call
public entry fun call(game: &mut PokerGame, ctx: &mut TxContext) {
  player_act(
    game,
    ctx.sender(),
    &mut PlayerAction::Call { amount: 0, all_in: false },
  );
}

// Player action: bet or raise
public entry fun bet_or_raise(
  game: &mut PokerGame,
  amount: u64,
  ctx: &mut TxContext,
) {
  player_act(
    game,
    ctx.sender(),
    &mut PlayerAction::BetOrRaise { amount, all_in: false },
  );
}

// ===== Game logic =====

entry fun generate_seed(r: &Random, ctx: &mut TxContext): vector<u8> {
  let mut generator = new_generator(r, ctx);
  let mut seed = vector[];
  let mut i = 0;
  while (i < SEED_LENGTH) {
    let byte = generator.generate_u8();
    seed.push_back(byte);
    i = i + 1;
  };
  seed
}

fun initialize_deck(game: &mut PokerGame) {
  // Clear the deck first
  game.deck = vector[];

  // Create a standard 52-card deck
  let mut suit = 0;
  while (suit < 4) {
    let mut value = 2;
    while (value <= 14) {
      let card = Card { suit: (suit as u8), value: (value as u8) };
      game.deck.push_back(card);
      value = value + 1;
    };
    suit = suit + 1;
  }
}

/// Shuffle the deck of cards
fun shuffle_deck(game: &mut PokerGame, seed: vector<u8>) {
  let deck_size = game.deck.length();
  let hash = sui::hash::keccak256(&seed);
  let mut i = deck_size;

  while (i > 1) {
    i = i - 1;
    let seed_byte = *hash.borrow(i % hash.length());
    let j = ((seed_byte as u64) + i) % i;
    game.deck.swap(i, j);
  }
}

/// Set the dealer position based on the current game state.
///
/// If the dealer position is empty, it will find the next occupied seat after the dealer.
/// If the game has been played before, it will move to the next player.
fun set_dealer_position(game: &mut PokerGame) {
  let mut dealer_pos = game.dealer_position;
  if (game.seats.borrow(dealer_pos).is_none()) {
    dealer_pos = game.seats.walk_occupied_seat(dealer_pos, 1); // Find the next occupied seat after dealer
  };
  if (game.hand_played > 0) {
    // Move to the next player after the dealer
    dealer_pos = game.seats.walk_occupied_seat(dealer_pos, 1);
  };
  game.dealer_position = dealer_pos;
}

/// Set blinds by taking chips (balances) from the small blinds and big blinds players.
fun set_blinds(game: &mut PokerGame) {
  let sb_pos = game.seats.walk_occupied_seat(game.dealer_position, 1); // Small blind is the next player after the dealer
  let bb_pos = game.seats.walk_occupied_seat(sb_pos, 1); // Big blind is the next occupied seat after small blind
  // Small blind
  let sb_amount = {
    let player = game.seats.borrow_mut(sb_pos).borrow_mut();
    // Take Small blind (half of the min bet) or remaining balance if less (force all-in)
    let amount = std::u64::min(player.balance, game.min_bet / 2);
    player.balance = player.balance - amount;
    player.current_bet = amount;
    player.total_contributed = amount;
    let all_in = player.balance == 0; // Check if player is all-in
    if (all_in) player.state = PlayerState::AllIn;
    emit(PlayerMoved {
      game_id: game.id.to_inner(),
      player: player.addr,
      action: PlayerAction::BetOrRaise { amount, all_in },
    });
    amount
  };
  // Big blind
  let bb_amount = {
    let player = game.seats.borrow_mut(bb_pos).borrow_mut();
    // Take Big blind (the min bet) or remaining balance if less (force all-in)
    let amount = std::u64::min(player.balance, game.min_bet);
    player.balance = player.balance - amount;
    player.current_bet = amount;
    player.total_contributed = amount;
    let all_in = player.balance == 0; // Check if player is all-in
    if (all_in) player.state = PlayerState::AllIn;
    emit(PlayerMoved {
      game_id: game.id.to_inner(),
      player: player.addr,
      action: PlayerAction::BetOrRaise { amount, all_in },
    });
    amount
  };
  // Update related game state
  game.pot = sb_amount + bb_amount; // Set the pot to the sum of actual blinds.
  game.current_bet = game.min_bet; // Set current bet to big blind amount (not taken from player in case of all-in)
}

/// Deal cards to all players in the game.
fun deal_cards(game: &mut PokerGame) {
  let seat_count = game.seats.count!(|s| s.is_some());
  let card_count = seat_count * CARDS_PER_PLAYER;
  // Take necessary cards from the deck first
  let mut cards = vector[];
  card_count.do!(|_| cards.push_back(game.deck.pop_back()));
  cards.reverse(); // Ensure cards are in the correct order (last dealt card is on top)
  // Start dealing cards to each player, starting from the next occupied seat after the dealer
  let mut seat = game.seats.walk_occupied_seat(game.dealer_position, 1);
  let mut i = 0;
  while (i < seat_count) {
    let player = game.seats.borrow_mut(seat).borrow_mut();
    player.cards = vector[]; // Reset player's cards
    CARDS_PER_PLAYER.do!(|_| player.cards.push_back(cards.pop_back())); // Deal required cards to each player
    seat = game.seats.walk_occupied_seat(seat, 1); // Move to the next occupied seat
    i = i + 1;
  };
}

fun sit_to_seat(
  game: &mut PokerGame,
  seat: u64,
  player_addr: address,
  buy_in: u64,
) {
  assert!(seat < MAX_PLAYERS, EInvalidSeat);
  assert!(game.seats[seat].is_none(), ESeatOccupied);
  game
    .seats
    .push_back(
      some(Player {
        addr: player_addr,
        cards: vector[],
        balance: buy_in,
        current_bet: 0,
        total_contributed: 0,
        state: PlayerState::Waiting,
      }),
    ); // Add player to the seat at the end
  game.seats.swap_remove(seat); // Swap to correct seat
}

/// Find player's seat by address. Abort with `EInvalidPlayer` if not found.
fun find_seat_index(game: &PokerGame, addr: address): u64 {
  let result = game.seats.find_index!(|s| s.is_some_and!(|p| p.addr == addr));
  if (result.is_some()) return result.destroy_some();
  abort EInvalidPlayer
}

fun player_act(
  game: &mut PokerGame,
  player_addr: address,
  action: &mut PlayerAction,
) {
  // ====== Validate Player & Action =====
  assert!(
    game.stage != GameStage::Waiting &&
    game.stage != GameStage::Ended,
    EGameNotStarted,
  ); // Game must be in progress
  let seat = game.find_seat_index(player_addr);
  let player = game.seats.borrow_mut(seat).borrow_mut();
  assert!(player.state == PlayerState::Active, EInvalidAction); // Player must be active to act

  // ====== Execute Action =====

  match (action) {
    PlayerAction::Fold => { player.state = PlayerState::Folded; },
    PlayerAction::Check => {
      assert!(game.current_bet == player.current_bet, EInvalidAction);
      player.state = PlayerState::Checked; // Mark player as moved
    },
    PlayerAction::Call { amount, all_in } => {
      let call_amount = std::u64::min(
        game.current_bet - player.current_bet, // Amount needed to call
        player.balance, // Use available balance if its lesser (all-in scenario)
      );
      player.balance = player.balance - call_amount; // Reduce player's balance
      game.pot = game.pot + call_amount; // And add that to the pot
      player.current_bet = player.current_bet + call_amount;
      player.total_contributed = player.total_contributed + call_amount;
      *amount = call_amount; // Set amount to call
      if (player.balance == 0) {
        *all_in = true; // Mark as all-in if balance is 0
        player.state = PlayerState::AllIn; // Mark player as all-in
      } else {
        player.state = PlayerState::Called; // Otherwise, just mark as moved
      };
    },
    PlayerAction::BetOrRaise { amount, all_in } => {
      assert!(*amount <= player.balance, EInvalidAmount);
      assert!(player.current_bet + *amount > game.current_bet, EInvalidAmount); // Amount must be enough to raise the game's current bet
      player.balance = player.balance - *amount; // Reduce player's balance
      game.pot = game.pot + *amount; // And add that to the pot
      player.current_bet = player.current_bet + *amount;
      player.total_contributed = player.total_contributed + *amount;
      game.current_bet = player.current_bet; // Update current bet to player's bet
      game.last_raise_position = some(seat); // Update last raise position to current player
      if (player.balance == 0) {
        *all_in = true; // Mark as all-in if balance is 0
        player.state = PlayerState::AllIn; // Mark player as all-in
      } else {
        player.state = PlayerState::RaisedOrBetted; // Otherwise, just mark as moved
      };
    },
  };

  print_debug(b"♦️ Player", &player.addr);
  print_debug(b"acted:", action);
  emit(PlayerMoved {
    game_id: game.id.to_inner(),
    player: player.addr,
    action: *action,
  });

  // ====== System action after player acted =====

  let maybe_next_player = game.find_next_actor(seat);
  if (maybe_next_player.is_some()) {
    // Set next player to active
    let next_player = maybe_next_player.destroy_some();
    let p = game.seats.borrow_mut(next_player).borrow_mut();
    p.state = PlayerState::Active;
    print_debug(b"➡️ Next player is: ", &next_player);
  } else {
    // No next player found, round is complete
    let next_stage = compute_next_stage(game);
    game.advance_game_stage(next_stage);
  };
}

fun compute_next_stage(game: &PokerGame): GameStage {
  let mut next_stage = game.stage;
  // No next player found, round is complete.
  match (next_stage) {
    GameStage::PreFlop => { next_stage = GameStage::Flop; },
    GameStage::Flop => { next_stage = GameStage::Turn; },
    GameStage::Turn => { next_stage = GameStage::River; },
    GameStage::River => { next_stage = GameStage::Showdown; },
    _ => { abort EInvalidGameState }, // Invalid state to advance
  };

  let all_in_or_folded = game.seats.count!(|s| s.is_some_and!(|p| {
    p.state == PlayerState::Folded || p.state == PlayerState::AllIn
  }));
  let active_players = game.seats.count!(|s| s.is_some());
  // If all but one player are folded or went all-in, we go to showdown
  if (all_in_or_folded >= active_players - 1) next_stage = GameStage::Showdown;
  next_stage
}

/// Calculate the game stage after a round ended.
fun advance_game_stage(game: &mut PokerGame, next_stage: GameStage) {
  match (next_stage) {
    GameStage::Flop => { deal_community_cards(game, 3); },
    GameStage::Turn => { deal_community_cards(game, 1); },
    GameStage::River => { deal_community_cards(game, 1); },
    GameStage::Showdown => {
      let community_cards_count = game.community_cards.length();
      deal_community_cards(game, 5 - community_cards_count); // Ensure we have 5 community cards
      // Process players' hands and determine winners
      identify_winners(game);
      check_and_create_side_pots(game); // Create side pots if needed
      distribute_pot(game); // Distribute main pot and side pots
      game.stage = GameStage::Ended; // Set game stage to ended
      game.hand_played = game.hand_played + 1; // Increment hands played
      emit(GameEnded { game_id: game.id.to_inner() }); // Emit game ended event
      print_debug(b"🏆 Game ended, winners: ", &game.winners);
      return // Exit early, no next stage after showdown
    },
    _ => { abort EInvalidGameState }, // Invalid state to advance
  };
  game.stage = next_stage; // Update game stage
  game.seats.do_mut!(|s| s.do_mut!(|p| {
    p.state = PlayerState::Waiting; // Reset all players to waiting state
    p.current_bet = 0; // Reset current bet for next round
  }));
  game.last_raise_position = none(); // Reset last raise position
  game.current_bet = 0; // Reset current bet for next round
  let dealer_position = game.dealer_position;
  let active_pos = game.seats.walk_occupied_seat(dealer_position, 1); // First player to act is small blind
  game.seats.borrow_mut(active_pos).do_mut!(|p| p.state = PlayerState::Active); // Set small blind player to active
  emit(RoundChanged { game_id: game.id.to_inner(), new_state: game.stage });
  print_debug(b"🎲 Game stage advanced to: ", &next_stage);
  print_debug(b"💰 Pot: ", &game.pot);
}

// // Create side pots for all-in scenarios
fun check_and_create_side_pots(game: &mut PokerGame) {
  // If there are no all-in players, no side pots needed
  if (!game.seats.any!(|s| s.is_some_and!(|p| p.state == PlayerState::AllIn)))
    return;

  // Collect all unique bet amounts from active players (not folded)
  let mut bet_levels = vector<u64>[];
  game.seats.filter!(|s| s.is_some_and!(|p| {
    p.state != PlayerState::Folded &&
    p.total_contributed > 0
  })).map!(|p| p.borrow().total_contributed).do_ref!(|bet| {
    if (!bet_levels.contains(bet)) bet_levels.push_back(*bet);
  });
  if (bet_levels.length() <= 1) return; // No bet levels no only one bet level, no side pots needed

  // Sort bet levels in ascending order
  bet_levels.merge_sort_by!(|a, b| *a < *b);

  bet_levels.do_ref!(|level| {
    if (game.side_pots.any!(|sp| sp.amount == *level)) return;
    // Create a side pot for each unique bet level
    let eligible_players = game.seats.filter!(|s| s.is_some_and!(|p| {
      p.state != PlayerState::Folded &&
      p.total_contributed >= *level
    })).map!(|p| p.borrow().addr);

    let mut side_pot = SidePot {
      eligible_players,
      amount: 0,
      winners: vector[],
    };
    game.seats.do_mut!(|s| s.do_mut!(|p| {
      if (!eligible_players.contains(&p.addr)) return; // Skip if player not eligible for this side pot
      let contribution = std::u64::min(
        p.total_contributed - *level,
        p.balance,
      ); // Amount to contribute to side pot
      p.balance = p.balance - contribution; // Reduce player's balance
      p.current_bet = p.current_bet - contribution; // Reduce player's current bet
      p.total_contributed = p.total_contributed - contribution; // Reduce player's total contributed
      side_pot.amount = side_pot.amount + contribution; // Add to side pot amount
    }));
    game.pot = game.pot - side_pot.amount; // Reduce main pot by side pot amount
    game.side_pots.push_back(side_pot);
    print_debug(b"💰 Side pot created: ", &side_pot);
  });
  assert!(game.pot == 0, EInvalidGameState); // Pot should not be 0 after side pots creation
}

fun deal_community_cards(game: &mut PokerGame, count: u64) {
  let mut i = 0;
  while (i < count) {
    // Burn cards
    match (game.community_cards.length()) {
      0 => { game.deck.pop_back(); }, // Burn before flop
      3 => { game.deck.pop_back(); }, // Burn before turn
      4 => { game.deck.pop_back(); }, // Burn before river
      _ => {},
    };
    let card = game.deck.pop_back();
    game.community_cards.push_back(card);
    i = i + 1;
  }
}

fun identify_winners(game: &mut PokerGame) {
  let participants = game
    .seats
    .filter!(|s| s.is_some_and!(|p| p.state != PlayerState::Folded))
    .map!(|s| {
      let p = s.borrow();
      let mut cards = vector<Card>[];
      p.cards.do_ref!(|c| cards.push_back(*c)); // Add player's cards
      game.community_cards.do_ref!(|c| cards.push_back(*c)); // Add community cards to player's hand
      let hand_rank = evaluate_hand(&cards);
      Participant { addr: p.addr, cards: cards, hand_rank }
    });
  game.winners = determine_winners(&participants); // Set winners for the main pot
  print_debug(b"🏆 Winners identified: ", &game.winners);

  let mut side_pots = game.side_pots;
  side_pots.do_mut!(|sp| {
    let participants = sp.eligible_players.map!(|participant| {
      let seat_index = game.find_seat_index(participant);
      let p = game.seats.borrow_mut(seat_index).borrow_mut();
      let mut cards = vector<Card>[];
      p.cards.do_ref!(|c| cards.push_back(*c)); // Clone player's cards
      game.community_cards.do_ref!(|c| cards.push_back(*c)); // Add community cards to player's hand
      let hand_rank = evaluate_hand(&cards);
      Participant { addr: p.addr, cards: cards, hand_rank }
    });
    sp.winners = determine_winners(&participants);
    print_debug(b"💰 Side pot winners identified: ", &sp.winners);
  });
}

/// Distribute the pot and side pots to players evenly
fun distribute_pot(game: &mut PokerGame) {
  // Distribute main pot
  if (game.pot > 0) {
    print_debug(b"💰 Distributing main pot: ", &game.pot);
    assert!(game.winners.length() > 0, EInvalidGameState); // Should have winners
    let share = game.pot / game.winners.length();
    let mut changes = game.pot % game.winners.length(); // Remainder if pot cannot be evenly divided
    game.seats.do_mut!(|s| s.do_mut!(|player| {
      if (!game.winners.contains(&player.addr)) return;
      player.balance = player.balance + share; // Add share to player's balance
      game.pot = game.pot - share; // Reduce pot by the share amount
      if (changes > 0) {
        // If there's a remainder, give it to the first active player
        player.balance = player.balance + changes;
        game.pot = game.pot - changes; // Reduce pot by the remainder
        changes = 0; // Reset changes to 0 after giving it out
      };
    }));
    assert!(game.pot == 0, EInvalidGameState); // Pot should be empty after distribution
  };

  // Distribute side pots, same logic as main pot
  if (game.side_pots.length() > 0) {
    let side_pots = game.side_pots; // Clone side pots to avoid mutating while iterating
    side_pots.do!(|side_pot| {
      print_debug(b"💰 Distributing side pot: ", &side_pot);
      assert!(side_pot.winners.length() > 0, EInvalidGameState); // Ensure there are winners
      let share = side_pot.amount / side_pot.winners.length();
      let mut changes = side_pot.amount % side_pot.winners.length();
      side_pot.winners.do_ref!(|addr| {
        let seat_index = game.find_seat_index(*addr);
        let player = game.seats.borrow_mut(seat_index).borrow_mut();
        player.balance = player.balance + share; // Add share to player's balance
        if (changes > 0) {
          player.balance = player.balance + changes; // Give remainder to the first eligible player
          changes = 0; // Reset changes to 0 after giving it out
        };
      });
    });
  };
}

// ===== Game helpers =====

/// Walk through the seats starting from `from` index and return the index of the `step`-th occupied seat.
fun walk_occupied_seat(
  seats: &vector<Option<Player>>,
  from: u64,
  step: u64,
): u64 {
  let total_seats = seats.length();
  let mut walked = 0;
  let mut seat = from; // Start walking from the given index
  while (walked < step) {
    seat = (seat + 1) % total_seats; // Move to next seat
    if (seats.borrow(seat).is_some()) {
      walked = walked + 1; // Increment walked count if seat is occupied
      if (walked == step) break; // Exit if we reached the desired step
    };
  };
  seat
}

use fun poker::game::walk_occupied_seat as vector.walk_occupied_seat;

/// Find the next player that must take action. Return `Option<u64>` with the index of the player or `None` if no player can act.
fun find_next_actor(game: &PokerGame, from_seat: u64): Option<u64> {
  let seats = &game.seats;
  let total_seats = seats.length();
  let mut seat = seats.walk_occupied_seat(from_seat, 1); // Start from the next occupied seat after `from_seat`
  let mut i = 0;
  let mut next_seat = none();
  let mut total_active_seats = 0;
  while (i < total_seats) {
    if (seats.borrow(seat).is_some_and!(|p| {
        // Player is waiting
        p.state == PlayerState::Waiting ||
        // Player has not folded or all-in but still need to match the current bet
        (
          p.state != PlayerState::Folded &&
          p.state != PlayerState::AllIn &&
          p.current_bet < game.current_bet
        )
      })) {
      if (total_active_seats == 0) next_seat = some(seat); // Set next seat to the first active player found
      total_active_seats = total_active_seats + 1; // Count active seats
    };
    seat = (seat + 1) % total_seats; // Move to next seat
    i = i + 1;
  };
  print_debug(b"ℹ️ Total active seats: ", &total_active_seats);

  // If only one player is left, check for special case
  if (next_seat.is_some() && total_active_seats == 1) {
    let next_player = seats[*next_seat.borrow()].borrow();
    let other_players = (*seats)
      .filter!(|s| s.is_some_and!(|p| p.addr != next_player.addr))
      .map!(|s| *s.borrow());
    // If all other players have folded or gone all-in, no further action needed
    if (other_players.all!(|p| p.state == PlayerState::Folded)) {
      print_debug(
        b"ℹ️ Only one player left, no next action needed.",
        &next_player.addr,
      );
      return none()
    };
  };

  next_seat
}

// ===== Hand Evaluation Functions =====

/// Determine the winners of the game based on players' hands
fun determine_winners(players: &vector<Participant>): vector<address> {
  // For each side pot, find the best hand among eligible players
  let mut best_rank: Option<HandRank> = none();
  let mut losers = vector<address>[];
  players.do_ref!(|p| {
    let rank = evaluate_hand(&p.cards);

    // If no best rank yet, set it to current hand rank
    if (best_rank.is_none()) best_rank = some(rank);

    let result = compare_hands(&rank, best_rank.borrow());
    if (result.is_none() || result.borrow() == true) {
      // If hand is equal or better, update best hand
      best_rank = some(rank);
    } else {
      // If current hand is worse, add to losers
      losers.push_back(p.addr);
    };
  });

  (*players).filter!(|p| !losers.contains(&p.addr)).map!(|p| p.addr)
}

/// Evaluate a 7-card hand (5 community + 2 hole cards) and return the best 5-card hand
fun evaluate_hand(cards: &vector<Card>): HandRank {
  assert!(cards.length() == 7, EInvalidGameState); // Must have exactly 7 cards

  // Convert cards to ranks and suits for evaluation
  let mut ranks: vector<u8> = vector[];
  let mut suits: vector<u8> = vector[];

  let mut i = 0;
  while (i < 7) {
    let card = cards.borrow(i);
    ranks.push_back(card.value);
    suits.push_back(card.suit);
    i = i + 1;
  };

  // Sort ranks for easier evaluation
  sort_ranks(&mut ranks);

  // Check for flush
  let flush_suit = check_flush(&suits);
  let is_flush = flush_suit != 255; // 255 indicates no flush

  // Check for straight
  let straight_high = check_straight(&ranks);
  let is_straight = straight_high != 0;

  // Check for royal flush
  if (is_flush && is_straight && straight_high == 14) {
    return HandRank {
      hand_type: HAND_ROYAL_FLUSH,
      primary_value: 14,
      secondary_value: 0,
      kickers: vector[],
    }
  };

  // Check for straight flush
  if (is_flush && is_straight) {
    return HandRank {
      hand_type: HAND_STRAIGHT_FLUSH,
      primary_value: straight_high,
      secondary_value: 0,
      kickers: vector[],
    }
  };

  // Count rank frequencies
  let rank_counts = count_ranks(&ranks);

  // Check for four of a kind
  let four_kind = find_four_of_a_kind(&rank_counts);
  if (four_kind != 0) {
    let kicker = find_highest_kicker(&ranks, four_kind, 1);
    return HandRank {
      hand_type: HAND_FOUR_OF_A_KIND,
      primary_value: four_kind,
      secondary_value: 0,
      kickers: vector[kicker],
    }
  };

  // Check for full house
  let (three_kind, pair_value) = find_full_house(&rank_counts);
  if (three_kind != 0 && pair_value != 0) {
    return HandRank {
      hand_type: HAND_FULL_HOUSE,
      primary_value: three_kind,
      secondary_value: pair_value,
      kickers: vector[],
    }
  };

  // Check for flush
  if (is_flush) {
    let flush_kickers = get_flush_kickers(&ranks, &suits, flush_suit);
    return HandRank {
      hand_type: HAND_FLUSH,
      primary_value: *flush_kickers.borrow(0),
      secondary_value: 0,
      kickers: flush_kickers,
    }
  };

  // Check for straight
  if (is_straight) {
    return HandRank {
      hand_type: HAND_STRAIGHT,
      primary_value: straight_high,
      secondary_value: 0,
      kickers: vector[],
    }
  };

  // Check for three of a kind
  if (three_kind != 0) {
    let kickers = find_kickers(&ranks, three_kind, 2);
    return HandRank {
      hand_type: HAND_THREE_OF_A_KIND,
      primary_value: three_kind,
      secondary_value: 0,
      kickers,
    }
  };

  // Check for two pair
  let pairs = find_pairs(&rank_counts);
  if (pairs.length() >= 2) {
    let high_pair = *pairs.borrow(0);
    let low_pair = *pairs.borrow(1);
    let kicker = find_highest_kicker(&ranks, high_pair, 1);
    let kicker2 = find_highest_kicker(&ranks, low_pair, 1);
    let final_kicker = if (kicker != low_pair && kicker != high_pair) kicker
    else kicker2;

    return HandRank {
      hand_type: HAND_TWO_PAIR,
      primary_value: high_pair,
      secondary_value: low_pair,
      kickers: vector[final_kicker],
    }
  };

  // Check for one pair
  if (pairs.length() == 1) {
    let pair_rank = *pairs.borrow(0);
    let kickers = find_kickers(&ranks, pair_rank, 3);
    return HandRank {
      hand_type: HAND_ONE_PAIR,
      primary_value: pair_rank,
      secondary_value: 0,
      kickers,
    }
  };

  // High card
  let kickers = get_high_card_kickers(&ranks);
  HandRank {
    hand_type: HAND_HIGH_CARD,
    primary_value: *kickers.borrow(0),
    secondary_value: 0,
    kickers,
  }
}

/// Compare two hands and return true if hand1 wins
fun compare_hands(hand1: &HandRank, hand2: &HandRank): Option<bool> {
  // Compare hand types first
  if (hand1.hand_type != hand2.hand_type) {
    return some(hand1.hand_type > hand2.hand_type)
  };

  // Same hand type, compare primary values
  if (hand1.primary_value != hand2.primary_value) {
    return some(hand1.primary_value > hand2.primary_value)
  };

  // Same primary value, compare secondary values
  if (hand1.secondary_value != hand2.secondary_value) {
    return some(hand1.secondary_value > hand2.secondary_value)
  };

  // Compare kickers
  compare_kickers(&hand1.kickers, &hand2.kickers)
}

// ===== Hand Evaluation Helper Functions =====

/// Sort ranks in descending order (highest first)
fun sort_ranks(ranks: &mut vector<u8>) {
  let len = ranks.length();
  let mut i = 0;
  while (i < len) {
    let mut j = i + 1;
    while (j < len) {
      if (*ranks.borrow(i) < *ranks.borrow(j)) {
        ranks.swap(i, j);
      };
      j = j + 1;
    };
    i = i + 1;
  };
}

/// Check for flush and return the suit (255 if no flush)
fun check_flush(suits: &vector<u8>): u8 {
  let mut suit_counts = vector[0u8, 0u8, 0u8, 0u8]; // Hearts, Diamonds, Clubs, Spades

  let mut i = 0;
  while (i < suits.length()) {
    let suit = *suits.borrow(i);
    let current_count = *suit_counts.borrow(suit as u64);
    *suit_counts.borrow_mut(suit as u64) = current_count + 1;
    i = i + 1;
  };

  i = 0;
  while (i < 4) {
    if (*suit_counts.borrow(i) >= 5) {
      return (i as u8)
    };
    i = i + 1;
  };

  255 // No flush
}

/// Check for straight and return the high card (0 if no straight)
fun check_straight(ranks: &vector<u8>): u8 {
  // Remove duplicates and sort
  let mut unique_ranks = vector[];
  let mut i = 0;
  while (i < ranks.length()) {
    let rank = *ranks.borrow(i);
    if (!unique_ranks.contains(&rank)) {
      unique_ranks.push_back(rank);
    };
    i = i + 1;
  };

  sort_ranks(&mut unique_ranks);

  // Check for 5 consecutive cards
  let unique_length = unique_ranks.length();
  if (unique_length < 5) {
    return 0 // Not enough unique ranks for a straight
  };

  i = 0;
  while (i <= unique_length - 5) {
    let mut consecutive = true;
    let mut j = 0;
    while (j < 4) {
      let current_rank = *unique_ranks.borrow(i + j);
      let next_rank = *unique_ranks.borrow(i + j + 1);
      if (current_rank != next_rank + 1) {
        consecutive = false;
        break
      };
      j = j + 1;
    };

    if (consecutive) {
      return *unique_ranks.borrow(i) // Return high card of straight
    };
    i = i + 1;
  };

  // Check for A-2-3-4-5 straight (wheel)
  if (unique_ranks.length() >= 5) {
    let has_ace = unique_ranks.contains(&14);
    let has_five = unique_ranks.contains(&5);
    let has_four = unique_ranks.contains(&4);
    let has_three = unique_ranks.contains(&3);
    let has_two = unique_ranks.contains(&2);

    if (has_ace && has_five && has_four && has_three && has_two) {
      return 5 // 5-high straight
    };
  };

  0 // No straight
}

/// Count frequency of each rank
fun count_ranks(ranks: &vector<u8>): vector<u8> {
  let mut counts: vector<u8> = vector[];
  let mut i = 0;
  while (i < 15) {
    counts.push_back(0);
    i = i + 1;
  };

  i = 0;
  while (i < ranks.length()) {
    let rank = *ranks.borrow(i);
    let current_count = *counts.borrow(rank as u64);
    *counts.borrow_mut(rank as u64) = current_count + 1;
    i = i + 1;
  };

  counts
}

/// Find four of a kind rank (0 if none)
fun find_four_of_a_kind(rank_counts: &vector<u8>): u8 {
  let mut i = 14;
  while (i >= 2) {
    if (*rank_counts.borrow(i) == 4) {
      return (i as u8)
    };
    i = i - 1;
  };
  0
}

/// Find full house (three of a kind, pair)
fun find_full_house(rank_counts: &vector<u8>): (u8, u8) {
  let mut three_kind = 0u8;
  let mut pair_value = 0u8;

  // Find three of a kind (highest)
  let mut i = 14;
  while (i >= 2) {
    if (*rank_counts.borrow(i) == 3) {
      three_kind = (i as u8);
      break
    };
    i = i - 1;
  };

  // Find pair (highest, different from three of a kind)
  i = 14;
  while (i >= 2) {
    let count = *rank_counts.borrow(i);
    if (
      (count == 2 || (count == 3 && (i as u8) != three_kind)) && (i as u8) != three_kind
    ) {
      pair_value = (i as u8);
      break
    };
    i = i - 1;
  };

  (three_kind, pair_value)
}

/// Find pairs in descending order
fun find_pairs(rank_counts: &vector<u8>): vector<u8> {
  let mut pairs: vector<u8> = vector[];

  let mut i = 14;
  while (i >= 2) {
    let count = *rank_counts.borrow(i);
    if (count == 2) {
      pairs.push_back(i as u8);
    } else if (count == 3) {
      // Three of a kind counts as a pair for full house detection
      pairs.push_back(i as u8);
    };
    i = i - 1;
  };

  pairs
}

/// Find the highest kicker excluding specified rank
fun find_highest_kicker(ranks: &vector<u8>, exclude_rank: u8, count: u8): u8 {
  let kickers = find_kickers(ranks, exclude_rank, count);
  if (kickers.length() > 0) {
    *kickers.borrow(0)
  } else {
    0
  }
}

/// Find kickers (cards not part of the main hand)
fun find_kickers(ranks: &vector<u8>, exclude_rank: u8, count: u8): vector<u8> {
  let mut kickers: vector<u8> = vector[];

  // Collect unused ranks in descending order
  let mut i = 0;
  let target_count = (count as u64);
  while (i < ranks.length() && kickers.length() < target_count) {
    let rank = *ranks.borrow(i);
    if (rank != exclude_rank) {
      kickers.push_back(rank);
    };
    i = i + 1;
  };

  kickers
}

/// Get flush kickers (5 highest cards of flush suit)
fun get_flush_kickers(
  ranks: &vector<u8>,
  suits: &vector<u8>,
  flush_suit: u8,
): vector<u8> {
  let mut flush_cards = vector[];

  let mut i = 0;
  while (i < suits.length()) {
    if (*suits.borrow(i) == flush_suit) {
      flush_cards.push_back(*ranks.borrow(i));
    };
    i = i + 1;
  };

  sort_ranks(&mut flush_cards);

  // Take top 5 cards
  let mut kickers = vector[];
  i = 0;
  while (i < 5 && i < flush_cards.length()) {
    kickers.push_back(*flush_cards.borrow(i));
    i = i + 1;
  };

  kickers
}

/// Get high card kickers (5 highest cards)
fun get_high_card_kickers(ranks: &vector<u8>): vector<u8> {
  let mut unique_ranks: vector<u8> = vector[];

  // Get unique ranks
  let mut i = 0;
  while (i < ranks.length()) {
    let rank = *ranks.borrow(i);
    if (!unique_ranks.contains(&rank)) {
      unique_ranks.push_back(rank);
    };
    i = i + 1;
  };

  sort_ranks(&mut unique_ranks);

  // Take top 5
  let mut kickers = vector[];
  i = 0;
  while (i < 5 && i < unique_ranks.length()) {
    kickers.push_back(*unique_ranks.borrow(i));
    i = i + 1;
  };

  kickers
}

/// Compare kickers arrays
fun compare_kickers(
  kickers1: &vector<u8>,
  kickers2: &vector<u8>,
): Option<bool> {
  let len = kickers1.length();
  let mut i = 0;
  while (i < len && i < kickers2.length()) {
    let k1 = *kickers1.borrow(i);
    let k2 = *kickers2.borrow(i);
    if (k1 != k2) {
      return some(k1 > k2)
    };
    i = i + 1;
  };
  none() // Tie
}

// ===== Accessors (Tests Only) =====

#[test_only]
/// [Test Only] Get the game stage
public fun is_ended(game: &PokerGame): bool {
  game.stage == GameStage::Ended
}

#[test_only]
/// [Test Only] Get the player state
public fun addr(player: &Player): address { player.addr }

#[test_only]
/// [Test Only] Get the player state
public fun balance(player: &Player): u64 { player.balance }

#[test_only]
/// [Test Only] Get the game stage
public fun buy_in(game: &PokerGame): u64 { game.buy_in }

#[test_only]
/// [Test Only] Get the game stage
public fun dealer_position(game: &PokerGame): u64 { game.dealer_position }

#[test_only]
/// [Test Only] Get the game stage
public fun treasury_balance(game: &PokerGame): u64 { game.treasury.value() }

#[test_only]
/// [Test Only] Get the game stage
public fun side_pots_count(game: &PokerGame): u64 {
  game.side_pots.length()
}

#[test_only]
/// [Test Only] Get the game stage
public fun get_pot(game: &PokerGame): u64 { game.pot }

#[test_only]
/// [Test Only] Get the game stage
public fun get_player(game: &PokerGame, player: address): &Player {
  let player_index = find_seat_index(game, player);
  game.seats.borrow(player_index).borrow()
}

#[test_only]
/// [Test Only] Get the game stage
public fun get_player_balance(game: &PokerGame, player: address): u64 {
  let player_index = find_seat_index(game, player);
  game.seats.borrow(player_index).borrow().balance
}

#[test_only]
/// [Test Only] Get the game stage
public fun test_find_next_actor(game: &PokerGame, from_seat: u64): Option<u64> {
  game.find_next_actor(from_seat)
}

// ===== Helper Functions for testing =====

#[test_only]
public entry fun start_with_seed_for_testing(
  game: &mut PokerGame,
  seed: vector<u8>,
  ctx: &TxContext,
) {
  start_with_seed(game, seed, ctx);
}

#[test_only]
/// Get the player state by address
public entry fun get_player_state(game: &PokerGame, player: address): u64 {
  let i = game.seats.find_index!(|s| s.is_some_and!(|p| p.addr == player));
  let player = game.seats.borrow(i.destroy_some()).borrow();
  match (player.state) {
    PlayerState::Waiting => 0,
    PlayerState::Active => 1,
    PlayerState::Checked => 2,
    PlayerState::Called => 3,
    PlayerState::RaisedOrBetted => 4,
    PlayerState::Folded => 5,
    PlayerState::AllIn => 6,
  }
}

#[test_only]
public fun get_seats(game: &PokerGame): &vector<Option<Player>> {
  &game.seats
}
