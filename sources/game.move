module poker::game;

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
const MIN_BUY_IN: u64 = 100_000_000; // 0.1 SUI

// ===== Game Constants =====

// Error codes
const EGameInProgress: u64 = 0x0000;
const EInvalidPlayerCount: u64 = 0x0001;
const EInsufficientBuyIn: u64 = 0x0002;
const EBuyInMismatch: u64 = 0x0003;
const EInvalidPlayer: u64 = 0x0004;
const EInvalidAction: u64 = 0x0005;
const EInvalidAmount: u64 = 0x0006;
const EAlreadyJoined: u64 = 0x0009;
const EInvalidSeed: u64 = 0x000A;
const EInvalidGameState: u64 = 0x000B;
const EInvalidHandSize: u64 = 0x000C;
const EGameFulled: u64 = 0x000D;

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
  hand_type: u8, // Type of hand (0-9)
  primary_value: u8, // Primary value for comparison (e.g., pair value, high card)
  secondary_value: u8, // Secondary value (e.g., kicker for pair, second pair for two pair)
  kickers: vector<u8>, // Additional kickers for tie-breaking
}

// Side pot information for all-in scenarios
public struct SidePot has drop, store {
  amount: u64,
  eligible_players: vector<address>, // Player addresses eligible for this pot
}

// Player information
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

// Main game object
public struct PokerGame has key {
  id: UID,
  // ================ Game State ================
  /// List of players in the game
  players: vector<Player>,
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
  /// Current game hand dealer position (index in players vector)
  dealer_position: u64,
  /// Current game stage
  stage: GameStage,
  /// Last player position that raised the bet in this round
  last_raise_position: Option<u64>,
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

public struct GameCreated has copy, drop {
  game_id: ID,
  buy_in: u64,
}

public struct PlayerJoined has copy, drop {
  game_id: ID,
  player: address,
}

public struct GameStarted has copy, drop {
  game_id: ID,
  num_players: u64,
}

public struct PlayerMoved has copy, drop {
  game_id: ID,
  player: address,
  action: PlayerAction,
}

public struct RoundChanged has copy, drop {
  game_id: ID,
  new_state: GameStage,
}

public struct GameEnded has copy, drop {
  game_id: ID,
}

public struct GameCanceled has copy, drop {
  game_id: ID,
}

public struct PlayerWithdrawn has copy, drop {
  game_id: ID,
  player: address,
  balance: u64,
}

// ===== Game Functions =====

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

  let first_player = Player {
    addr: owner_addr,
    cards: vector[],
    balance: buy_in,
    current_bet: 0,
    total_contributed: 0,
    state: PlayerState::Waiting,
  };

  let game = PokerGame {
    id,
    // ===== Game State =====
    players: vector[first_player],
    deck: vector[],
    community_cards: vector[],
    side_pots: vector[],
    pot: 0,
    current_bet: 0,
    stage: GameStage::Waiting,
    dealer_position: 0,
    last_raise_position: option::none(),
    // ===== Game Configuration =====
    buy_in,
    min_bet,
    // ===== Game Metadata =====
    owner: owner_addr,
    hand_played: 0,
    treasury: payment.into_balance(), // Initialize treasury with creator's payment
  };

  emit(GameCreated { game_id, buy_in });
  emit(PlayerJoined { game_id, player: owner_addr });

  transfer::share_object(game);

  game_id
}

/// Join an existing poker game
public entry fun join(
  game: &mut PokerGame,
  payment: Coin<SUI>,
  ctx: &mut TxContext,
) {
  let player_addr = ctx.sender();
  assert!(game.stage == GameStage::Waiting, EGameInProgress);
  assert!(game.players.length() < MAX_PLAYERS, EGameFulled);
  assert!(payment.value() == game.buy_in, EBuyInMismatch);
  assert!(game.players.all!(|p| p.addr != player_addr), EAlreadyJoined);

  // Add player to the game
  game
    .players
    .push_back(Player {
      addr: player_addr,
      cards: vector[],
      balance: game.buy_in,
      current_bet: 0,
      total_contributed: 0,
      state: PlayerState::Waiting,
    });
  game.treasury.join(payment.into_balance()); // Add payment to treasury
  emit(PlayerJoined { game_id: game.id.to_inner(), player: player_addr });
}

/// Cancel the poker game and refund all players
public entry fun cancel_game(game: PokerGame, ctx: &mut TxContext) {
  // Only owner can cancel the game
  assert!(ctx.sender() == game.owner, EInvalidPlayer);

  // Check if game is still waiting for players
  assert!(game.stage == GameStage::Waiting, EInvalidGameState);

  let PokerGame { id, mut treasury, mut players, .. } = game;
  players.do_mut!(|player| {
    // Refund each player's balance
    if (player.balance > 0) {
      let funds = treasury.split(player.balance);
      transfer::public_transfer(funds.into_coin(ctx), player.addr);
      player.balance = 0; // Reset player balance
    };
  });
  treasury.destroy_zero();

  emit(GameCanceled { game_id: id.to_inner() });

  // Delete the game
  id.delete();
}

/// Start the poker game if we have enough players
entry fun start_game(game: &mut PokerGame, r: &Random, ctx: &mut TxContext) {
  let seed = generate_seed(r, ctx);
  start_game_with_seed(game, seed, ctx)
}

#[test_only]
public entry fun start_game_with_seed_for_testing(
  game: &mut PokerGame,
  seed: vector<u8>,
  ctx: &TxContext,
) {
  start_game_with_seed(game, seed, ctx);
}

fun start_game_with_seed(
  game: &mut PokerGame,
  seed: vector<u8>,
  ctx: &TxContext,
) {
  let player_count = game.players.length();

  assert!(
    player_count >= MIN_PLAYERS && player_count <= MAX_PLAYERS,
    EInvalidPlayerCount,
  );

  assert!(seed.length() == SEED_LENGTH, EInvalidSeed);
  assert!(
    game.stage == GameStage::Waiting || game.stage == GameStage::Ended,
    EInvalidGameState,
  );

  // Only owner can start the game
  assert!(ctx.sender() == game.owner, EInvalidPlayer);

  if (game.hand_played > 0) {
    game.players.do_mut!(|p| {
      p.current_bet = 0; // Reset all players' current bet
      p.total_contributed = 0; // Reset total contributed for next hand
      p.cards = vector[]; // Reset player cards
      p.state = PlayerState::Waiting; // Reset player state
    });
    game.dealer_position = (game.dealer_position + 1) % player_count; // Move dealer position to next player
  };
  set_blinds(game);
  initialize_deck(game);
  shuffle_deck(game, seed);

  // Deal cards to players
  game.players.do_mut!(|p| {
    p.cards = vector[]; // Reset player cards
    loop {
      p.cards.push_back(game.deck.pop_back());
      if (p.cards.length() == CARDS_PER_PLAYER) break;
    }
  });

  game.stage = GameStage::PreFlop; // Advance to pre-flop stage
  game.last_raise_position =
    option::some((game.dealer_position + 2) % player_count); // Big blind is the last raiser
  let current_player = game
    .players
    .borrow_mut((game.dealer_position + 3) % player_count); // First to act is the player after the big blind
  current_player.state = PlayerState::Active; // Set first player to active

  // Emit event
  emit(GameStarted { game_id: game.id.to_inner(), num_players: player_count });
}

// ===== Player Actions =====

/// Withdraw balance from the game
entry fun withdraw(game: &mut PokerGame, ctx: &mut TxContext) {
  assert!(game.stage == GameStage::Ended, EInvalidGameState); // Game must be over to claim pot
  let player_addr = ctx.sender();
  let player_index = find_player_index(game, player_addr);
  let player = game.players.borrow_mut(player_index);
  let amount = player.balance;
  assert!(amount > 0, EInvalidAction); // Player must have winnings to withdraw
  assert!(game.treasury.value() >= amount, EInvalidAction); // Check if pot has enough balance
  player.balance = 0; // Reset player balance to 0
  let winnings = game.treasury.split(amount).into_coin(ctx);
  transfer::public_transfer(winnings, player_addr); // Take balance from game pot to player's coin
  emit(PlayerWithdrawn {
    game_id: game.id.to_inner(),
    player: player_addr,
    balance: amount,
  });
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
  let amount = game.current_bet;
  player_act(
    game,
    ctx.sender(),
    &mut PlayerAction::Call { amount, all_in: false },
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

// ===== Helper Functions =====

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

/// Set blinds by taking chips (balances) from the small blinds and big blinds players.
fun set_blinds(game: &mut PokerGame) {
  let sb_pos = (game.dealer_position + 1) % game.players.length();
  let bb_pos = (game.dealer_position + 2) % game.players.length();
  // Small blind
  let sb_amount = {
    let player = game.players.borrow_mut(sb_pos);
    // Take Small blind (half of the min bet) or remaining balance if less (force all-in)
    let amount = std::u64::min(player.balance, game.min_bet / 2);
    player.balance = player.balance - amount;
    player.current_bet = amount;
    player.total_contributed = amount;
    if (player.balance == 0) player.state = PlayerState::AllIn;
    emit(PlayerMoved {
      game_id: game.id.to_inner(),
      player: player.addr,
      action: PlayerAction::BetOrRaise {
        amount,
        all_in: player.state == PlayerState::AllIn,
      },
    });
    amount
  };
  // Big blind
  let bb_amount = {
    let player = game.players.borrow_mut(bb_pos);
    // Take Big blind (the min bet) or remaining balance if less (force all-in)
    let amount = std::u64::min(player.balance, game.min_bet);
    player.balance = player.balance - amount;
    player.current_bet = amount;
    player.total_contributed = amount;
    if (player.balance == 0) player.state = PlayerState::AllIn;
    emit(PlayerMoved {
      game_id: game.id.to_inner(),
      player: player.addr,
      action: PlayerAction::BetOrRaise {
        amount,
        all_in: player.state == PlayerState::AllIn,
      },
    });
    amount
  };
  // Update related game state
  game.pot = sb_amount + bb_amount; // Set the pot to the sum of actual blinds.
  game.current_bet = game.min_bet; // Set current bet to big blind amount (not taken from player in case of all-in)
}

/// Find player index by address. Abort with `EInvalidPlayer` if not found.
fun find_player_index(game: &PokerGame, addr: address): u64 {
  let mut i = 0;
  while (i < game.players.length()) {
    let player = game.players.borrow(i);
    if (player.addr == addr) { return i };
    i = i + 1;
  };
  abort EInvalidPlayer
}

fun player_act(
  game: &mut PokerGame,
  player_addr: address,
  action: &mut PlayerAction,
) {
  // ====== Validate Player & Action =====
  let maybe_player_index = game.players.find_index!(|p| p.addr == player_addr);
  assert!(maybe_player_index.is_some(), EInvalidPlayer);
  let player_index = maybe_player_index.destroy_some();
  let player = game.players.borrow_mut(player_index);
  assert!(
    game.stage != GameStage::Waiting &&
    game.stage != GameStage::Ended &&
    player.state == PlayerState::Active,
    EInvalidAction,
  );

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
      player.balance = player.balance - call_amount;
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
      assert!(player.current_bet + *amount > game.current_bet, EInvalidAction); // Amount must be enough to raise the game's current bet
      player.balance = player.balance - *amount;
      player.current_bet = player.current_bet + *amount;
      player.total_contributed = player.total_contributed + *amount;
      game.current_bet = player.current_bet; // Update current bet to player's bet
      game.last_raise_position = option::some(player_index); // Update last raise position to current player
      if (player.balance == 0) {
        *all_in = true; // Mark as all-in if balance is 0
        player.state = PlayerState::AllIn; // Mark player as all-in
      } else {
        player.state = PlayerState::RaisedOrBetted; // Otherwise, just mark as moved
      };
    },
  };

  emit(PlayerMoved {
    game_id: game.id.to_inner(),
    player: player.addr,
    action: *action,
  });

  // ====== Move to the next player =====
  {
    // Continue the round, make the next player active
    let mut next_player = (player_index + 1) % game.players.length();
    let mut i = 0;
    while (i < game.players.length()) {
      let next_player_state = game.players.borrow(next_player).state;
      if (next_player_state == PlayerState::Waiting) { break }; // Found next waiting player
      next_player = (next_player + 1) % game.players.length(); // Move to next player
      i = i + 1;
    };
    game.players.borrow_mut(next_player).state = PlayerState::Active; // Set next player to active
  };

  // ====== Check if round is complete =====
  if (
    is_all_folded(&game.players) || // This also ended the hand
    is_all_checked(&game.players) || // All players checked, proceed to next stage
    is_all_called(&game.players) // All players called the current bet, proceed to next stage
  ) {
    // Round is complete, calculate game and advance game stage
    check_and_create_side_pots(game);
    calculate_game_stage(game);
  }
}

/// Calculate the game stage after a round ended.
fun calculate_game_stage(game: &mut PokerGame) {
  // The round is complete if all players have either moved, folded, or gone all-in.

  // ====== Check if the hand ended ======
  if (
    is_all_folded(&game.players) ||
    game.stage == GameStage::River // players finished betting on the river
  ) {
    // Game ended, process players' hands and distribute pot
    process_players_hands(game);
    distribute_pot(game);
    game.stage = GameStage::Ended;
    game.hand_played = game.hand_played + 1; // Increment hands played
    emit(GameEnded { game_id: game.id.to_inner() });
    return
  };

  // ====== Advance to the next stage ======

  match (game.stage) {
    GameStage::PreFlop => {
      // Deal the flop (3 community cards)
      deal_community_cards(game, 3);
      game.stage = GameStage::Flop;
    },
    GameStage::Flop => {
      // Deal the turn (1 community card)
      deal_community_cards(game, 1);
      game.stage = GameStage::Turn;
    },
    GameStage::Turn => {
      // Deal the river (1 community card)
      deal_community_cards(game, 1);
      game.stage = GameStage::River;
    },
    _ => { abort EInvalidGameState }, // Invalid state to advance
  };

  // ===== Prepare for the next round =====

  game.players.do_mut!(|p| {
    p.state = PlayerState::Waiting; // Reset active players to waiting state
    p.current_bet = 0; // Reset current bet for next round
  });
  let active_pos = (game.dealer_position + 1) % game.players.length(); // First player to act is small blind
  game.players.borrow_mut(active_pos).state = PlayerState::Active; // Set small blind player to active
  game.last_raise_position = option::none(); // Reset last raise position

  emit(RoundChanged { game_id: game.id.to_inner(), new_state: game.stage });
}

// Create side pots for all-in scenarios
fun check_and_create_side_pots(game: &mut PokerGame) {
  // If there are no all-in players, no side pots needed
  if (!game.players.any!(|p| p.state == PlayerState::AllIn)) return;

  // Collect all unique bet amounts from active players (not folded)
  let mut bet_levels = vector<u64>[];
  game
    .players
    .filter!(|p| p.state != PlayerState::Folded && p.total_contributed > 0)
    .map!(|p| p.total_contributed)
    .do_ref!(|bet| {
      if (!bet_levels.contains(bet)) bet_levels.push_back(*bet);
    });
  if (bet_levels.length() <= 1) return; // No bet levels no only one bet level, no side pots needed

  // Sort bet levels in ascending order
  bet_levels.merge_sort_by!(|a, b| *a < *b);

  bet_levels.do_ref!(|level| {
    if (game.side_pots.any!(|sp| sp.amount == *level)) return;
    // Create a side pot for each unique bet level
    let eligible_players = game
      .players
      .filter!(
        |p| p.state != PlayerState::Folded && p.total_contributed >= *level,
      )
      .map!(|p| p.addr);

    let mut side_pot = SidePot { eligible_players, amount: 0 };
    game.players.do_mut!(|p| {
      if (!eligible_players.contains(&p.addr)) return; // Skip if player not eligible for this side pot
      let contribution = std::u64::min(p.total_contributed - *level, p.balance); // Amount to contribute to side pot
      p.balance = p.balance - contribution; // Reduce player's balance
      p.current_bet = p.current_bet - contribution; // Reduce player's current bet
      p.total_contributed = p.total_contributed - contribution; // Reduce player's total contributed
      side_pot.amount = side_pot.amount + contribution; // Add to side pot amount
    });
    game.pot = game.pot - side_pot.amount; // Reduce main pot by side pot amount
    game.side_pots.push_back(side_pot);
  });
  assert!(game.pot == 0, EInvalidAction); // Pot should not be 0 after side pots creation
}

fun deal_community_cards(game: &mut PokerGame, count: u64) {
  let mut i = 0;
  while (i < count) {
    let card = game.deck.pop_back();
    game.community_cards.push_back(card);
    i = i + 1;
  }
}

fun process_players_hands(game: &mut PokerGame) {
  game.side_pots.do_mut!(|sp| {
    // For each side pot, find the best hand among eligible players
    let mut best_hand: Option<address> = option::none();
    let mut best_rank: Option<HandRank> = option::none();
    let mut losers = vector<address>[];
    sp.eligible_players.do_ref!(|addr| {
      let player_index = game.players.find_index!(|p| p.addr == *addr);
      if (player_index.is_none()) {
        // Skip if player not found
        losers.push_back(*addr);
        return
      };
      let player = game.players.borrow(player_index.destroy_some());
      let mut cards = vector<Card>[];
      game.community_cards.do_ref!(|c| cards.push_back(*c)); // Add community cards to player's hand
      player.cards.do_ref!(|c| cards.push_back(*c)); // Add player's hole cards to community cards
      let hand_rank = evaluate_hand(&cards);
      if (best_hand.is_none()) {
        best_hand = option::some(*addr);
        best_rank = option::some(hand_rank);
      };
      let mut result = compare_hands(&hand_rank, &best_rank.extract());
      if (result.is_none() || result.extract()) {
        // Current hand is equal or better, update best hand
        best_hand = option::some(*addr);
        best_rank = option::some(hand_rank);
      } else if (result.extract() == false) {
        // If hand is worse, add to losers
        losers.push_back(*addr);
      };
    });
  });
}

/// Distribute the pot and side pots to players evenly
fun distribute_pot(game: &mut PokerGame) {
  // Distribute main pot
  {
    // Find eligible players who haven't folded
    let eligibles = game
      .players
      .filter!(|p| p.state != PlayerState::Folded)
      .map!(|p| p.addr);
    let share = game.pot / eligibles.length();
    let mut changes = game.pot % eligibles.length(); // Remainder if pot cannot be evenly divided
    game.players.do_mut!(|player| {
      if (!eligibles.contains(&player.addr)) return;

      player.balance = player.balance + share; // Add share to player's balance
      game.pot = game.pot - share; // Reduce pot by the share amount
      if (changes > 0) {
        // If there's a remainder, give it to the first active player
        player.balance = player.balance + changes;
        game.pot = game.pot - changes; // Reduce pot by the remainder
        changes = 0; // Reset changes to 0 after giving it out
      };
    });
    assert!(game.pot == 0, EInvalidAction); // Pot should be empty after distribution
  };

  // Distribute side pots, same logic as main pot
  {
    game.side_pots.do_mut!(|side_pot| {
      let share = side_pot.amount / side_pot.eligible_players.length();
      let mut changes = side_pot.amount % side_pot.eligible_players.length();
      side_pot.eligible_players.do_mut!(|addr| {
        let player_index = game.players.find_index!(|p| p.addr == addr);
        if (player_index.is_none()) return; // Skip if player not found
        let player = game.players.borrow_mut(player_index.destroy_some());
        player.balance = player.balance + share; // Add share to player's balance
        if (changes > 0) {
          player.balance = player.balance + changes; // Give remainder to the first eligible player
          changes = 0; // Reset changes to 0 after giving it out
        };
      });
    });
    assert!(game.side_pots.all!(|sp| sp.amount == 0), EInvalidAction); // All side pots should be empty after distribution
  };
}

// ===== Game status check =====
fun is_all_folded(players: &vector<Player>): bool {
  // Check if all players have folded
  players.count!(|p| p.state != PlayerState::Folded && p.state != PlayerState::AllIn) <= 1
}

fun is_all_checked(players: &vector<Player>): bool {
  // Check if all players have checked
  players.count!(|p| p.state != PlayerState::Checked && p.state != PlayerState::AllIn) <= 1
}

fun is_all_called(players: &vector<Player>): bool {
  // Check if all players have called the current bet
  players
    .count!(|p| p.state != PlayerState::Called && p.state != PlayerState::AllIn) <= 1
}

// ===== Hand Evaluation Functions =====

/// Evaluate a 7-card hand (5 community + 2 hole cards) and return the best 5-card hand
fun evaluate_hand(cards: &vector<Card>): HandRank {
  assert!(cards.length() == 7, EInvalidHandSize);

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
    return option::some(hand1.hand_type > hand2.hand_type)
  };

  // Same hand type, compare primary values
  if (hand1.primary_value != hand2.primary_value) {
    return option::some(hand1.primary_value > hand2.primary_value)
  };

  // Same primary value, compare secondary values
  if (hand1.secondary_value != hand2.secondary_value) {
    return option::some(hand1.secondary_value > hand2.secondary_value)
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
      return option::some(k1 > k2)
    };
    i = i + 1;
  };
  option::none() // Tie
}

// ===== Accessors (Tests Only) =====

#[test_only]
public fun is_ended(game: &PokerGame): bool {
  game.stage == GameStage::Ended
}

#[test_only]
public fun buy_in(game: &PokerGame): u64 { game.buy_in }

#[test_only]
public fun dealer_position(game: &PokerGame): u64 { game.dealer_position }

#[test_only]
public fun treasury_balance(game: &PokerGame): u64 { game.treasury.value() }

#[test_only]
public fun side_pots_count(game: &PokerGame): u64 {
  game.side_pots.length()
}

#[test_only]
public fun get_player_balance(game: &PokerGame, player: address): u64 {
  let player_index = find_player_index(game, player);
  game.players.borrow(player_index).balance
}
