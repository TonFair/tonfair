tolk 1.2

// ============================================================
// event_pool.tolk — контракт EventPool (Tolk 1.2)
// Optimistic Oracle version
//
// Жизненный цикл:
//   1. Деплой (exchange отправляет 0.1 TON + stateInit)
//   2. Добавление сделок: vault'ы пополняют через DepositForDeal (0x105)
//   3. DealFunded (0x110) → exchange при полном финансировании
//   4. Exchange предлагает результат: ProposeResult (0x600)
//   5. Окно оспаривания (getChallengePeriod(eventType)): участник может вызвать Challenge (0x601) + 10 TON
//   6. Super Oracle выносит решение: OracleResolve (0x602), или истекает окно
//   7. Любой вызывает Settle (0x700): распределяет по результату
// ============================================================

// --- КОНСТАНТЫ ---

const DEPLOY_THRESHOLD: int = ton("0.5");
const DEPLOY_FEE: int = ton("0.02");
const TRANSFER_GAS_FEE: int = ton("0.02");
const DEPOSIT_TOLERANCE: int = ton("0.001");
const EXCHANGE_FEE_PCT: int = 5;
const CHALLENGE_PERIOD_DEFAULT: int = 21600; // 6 часов (SPORT, PREDICTION)
const CHALLENGE_PERIOD_UPDOWN: int = 300;   // 5 минут (UP_DOWN, type 101–105)
const DISPUTE_EMERGENCY: int = 259200;      // 3 суток
const DISPUTE_DEPOSIT: int = ton("0.1");     // 10 TON залог challenger'а, // todo 0.1 - временно для дебага

// ResultState (uint2)
const RS_PENDING: int = 0;    // результат не предложен
const RS_PROPOSED: int = 1;   // биржа предложила; идёт окно оспаривания
const RS_DISPUTED: int = 2;   // оспорено; ждём Super Oracle
const RS_RESOLVED: int = 3;   // Oracle выставил окончательный результат

// --- КОДЫ ОШИБОК ---

const ERR_EXCHANGE_ONLY: int = 101;
const ERR_INVALID_DEAL_ID: int = 102;
const ERR_DEAL_NOT_FOUND: int = 104;
const ERR_NOT_PARTICIPANT: int = 107;
const ERR_DEALS_COUNT_ZERO: int = 108;
const ERR_EXCHANGE_ONLY_DEACTIVATE: int = 109;
const ERR_RESULT_NOT_SET: int = 110;
const ERR_NOT_SETTLEABLE: int = 112;
const ERR_WRONG_STATE: int = 113;
const ERR_ALREADY_DISPUTED: int = 114;
const ERR_DISPUTE_DEPOSIT_WRONG: int = 115;
const ERR_ORACLE_ONLY: int = 116;
const ERR_CHALLENGE_PERIOD_OVER: int = 117;
const ERR_INVALID_CONFIG: int = 118;
const ERR_INVALID_BET_TYPE: int = 119;

// Возвращает окно оспаривания в секундах по типу события.
// UP_DOWN (101–105): 5 мин — результат объективен (цена закрытия свечи).
// Прочие (SPORT=0, PREDICTION=100, ...): 6 ч.
// Маппинг зафиксирован в коде контракта — другое значение технически невозможно.
@pure
fun getChallengePeriod(eventType: int): int {
    return (eventType >= 101 && eventType <= 105) ? CHALLENGE_PERIOD_UPDOWN : CHALLENGE_PERIOD_DEFAULT;
}

// --- СТРУКТУРЫ ДАННЫХ ---

// Суммы одной сделки вынесены в ref-ячейку: 4 coins-поля суммарно до ~500 бит,
// что не даёт им переполнить root-ячейку DealData (267+267+4+64 = 602 бит без ref).
struct DealAmounts {
    amountBuy: coins     // требуемый депозит покупателя
    amountSell: coins    // требуемый депозит продавца
    depositedBuy: coins  // фактически внесено покупателем
    depositedSell: coins // фактически внесено продавцом
}

// Данные одной сделки. betType/betParam хранятся здесь для on-chain определения победителя.
// Root-ячейка: 267+267+4+64+1ref = 603 бита — гарантированно вмещается без suppress.
struct DealData {
    userBuy: address
    userSell: address
    betType: uint4      // тип ставки (0–8), см. isWinForBuy
    betParam: uint64    // параметр ставки (кодировка по типу / market id для prediction)
    amounts: cell       // ref → DealAmounts
}

struct Actors {
    exchange: address
    challenger: address
    oracle: address
}

// --- СООБЩЕНИЯ ---

struct (0x00000105) MsgDepositForDeal {
    dealId: uint64
    amountBuy: coins
    amountSell: coins
    vaultBuy: address
    vaultSell: address
    betType: uint4
    betParam: uint64
}

// 0x600: Предложить результат. Только exchange. PENDING или PROPOSED (до Challenge).
// scoreHome=-1 AND scoreAway=-1 = void (отмена события).
struct (0x00000600) MsgProposeResult {
    scoreHome: int16
    scoreAway: int16
    predictionResult: uint2
}

// 0x601: Оспорить результат. Участник сделки (userBuy или userSell).
// Только в PROPOSED + в пределах CHALLENGE_PERIOD. Attached value == DISPUTE_DEPOSIT (10 TON).
struct (0x00000601) MsgChallenge {
    dealId: uint64
}

// 0x602: Финальный результат от Super Oracle. Только oracle address. Только DISPUTED.
struct (0x00000602) MsgOracleResolve {
    scoreHome: int16
    scoreAway: int16
    predictionResult: uint2
}

// 0x700: Урегулировать сделку. Permissionless. Логика зависит от resultState и времени.
struct (0x00000700) MsgSettle {
    dealId: uint64
}

// 0x500: Вывести комиссии на exchange и уничтожить контракт.
struct (0x00000500) MsgWithdrawFees {}

// 0xdeadbeef: Экстренная деактивация.
struct (0xdeadbeef) MsgDeactivateAndWithdraw {}

// --- ХРАНИЛИЩЕ ---
// actors хранится в reference cell, чтобы освободить место под market/predictionResult/int16 scores.
struct Storage {
    startTime: uint32
    eventId: uint64
    market: uint64
    deals: map<uint64, DealData>
    dealsCount: uint32
    resultState: uint2    // RS_PENDING / RS_PROPOSED / RS_DISPUTED / RS_RESOLVED
    scoreHome: int16      // sports only; -1:-1 = void
    scoreAway: int16      // sports only; -1:-1 = void
    predictionResult: uint2 // 0=none, 1=yes, 2=no, 3=cancel
    proposedAt: uint32    // unix timestamp последнего ProposeResult
    challengedAt: uint32  // unix timestamp Challenge (0 если не было)
    eventType: uint10     // тип события (0=sport, 100=prediction, 101-105=up_down); max 1023
    actors: cell
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

fun loadActors(storage: Storage): Actors {
    return Actors.fromCell(storage.actors);
}

fun saveActors(storage: Storage, actors: Actors) {
    storage.actors = actors.toCell();
}

// --- ОПРЕДЕЛЕНИЕ ПОБЕДИТЕЛЯ ---

// Возвращает: 1 = BUY побеждает, 0 = SELL побеждает, -1 = push (возврат обоим).
//
// Конвенция биржи: SELL = бэкинг (выигрывает когда исход случился),
//                  BUY  = лай    (выигрывает когда исход НЕ случился).
// Исключение: TOTAL (betType 2,3) — BUY бэкит выбранную сторону (OVER/UNDER).
//
// betParam кодирует рынок со стороны BUY-ордера (по данным из orders_ton):
//   0 (1X2):  0=хозяева, 1=ничья, 2=гости
//   1 (DC):   0=1X, 1=X2, 2=12
//   2 (OVER): порог × 10
//   3 (UNDER):порог × 10
//   4 (HCAP_HOME): гандикап × 10 + 1000
//   5 (HCAP_AWAY): гандикап × 10 + 1000
//   6 (CS):   (home << 8) | away
//   7 (EO):   0=чёт, 1=нечёт
fun isWinForBuy(betType: int, betParam: int, scoreHome: int, scoreAway: int, predictionResult: int): int {
    val total: int = scoreHome + scoreAway;

    if (betType == 0) { // RESULT_1X2 — BUY = лай: выигрывает когда исход НЕ betParam
        val result = (scoreHome > scoreAway) ? 0 : ((scoreHome < scoreAway) ? 2 : 1);
        return (result != betParam) ? 1 : 0;
    }

    if (betType == 1) { // DOUBLE_CHANCE — BUY = лай: выигрывает только когда случился исключённый исход
        val result = (scoreHome > scoreAway) ? 0 : ((scoreHome < scoreAway) ? 2 : 1);
        val wins =
            (betParam == 0) ? (result == 2) :   // 1X исключает гостей: BUY wins когда гости
            (betParam == 1) ? (result == 0) :   // X2 исключает хозяев: BUY wins когда хозяева
            (result == 1);                       // 12 исключает ничью:  BUY wins когда ничья
        return wins ? 1 : 0;
    }

    if (betType == 2) { // TOTAL_OVER — BUY = бэкинг OVER: выигрывает когда total > порог
        val total10 = total * 10;
        if (total10 == betParam) { return -1; }
        return (total10 > betParam) ? 1 : 0;
    }

    if (betType == 3) { // TOTAL_UNDER — BUY = бэкинг UNDER: выигрывает когда total < порог
        val total10 = total * 10;
        if (total10 == betParam) { return -1; }
        return (total10 < betParam) ? 1 : 0;
    }

    if (betType == 4) { // HANDICAP_HOME — BUY = лай: выигрывает когда хозяева НЕ выигрывают с форой
        val h: int = betParam - 1000;
        val eff: int = scoreHome * 10 + h - scoreAway * 10;
        if (eff == 0) { return -1; }
        return (eff < 0) ? 1 : 0;
    }

    if (betType == 5) { // HANDICAP_AWAY — BUY = лай: выигрывает когда гости НЕ выигрывают с форой
        val h: int = betParam - 1000;
        val eff: int = scoreAway * 10 + h - scoreHome * 10;
        if (eff == 0) { return -1; }
        return (eff < 0) ? 1 : 0;
    }

    if (betType == 6) { // EXACT_SCORE — BUY = лай: выигрывает когда счёт НЕ совпал
        val predHome: int = betParam >> 8;
        val predAway: int = betParam & 0xFF;
        return ((predHome != scoreHome) || (predAway != scoreAway)) ? 1 : 0;
    }

    if (betType == 7) { // EVEN_ODD — BUY = лай: выигрывает когда чётность НЕ совпала
        return ((total % 2) != betParam) ? 1 : 0;
    }

    if (betType == 8) { // PREDICTION — BUY = ставка на NO, SELL = ставка на YES
        if (predictionResult == 3) { return -1; }
        return (predictionResult == 2) ? 1 : 0;
    }
    throw ERR_INVALID_BET_TYPE; // betType 9–15 не поддерживается
}

fun hasSportsResultChanged(oldHome: int, oldAway: int, msgHome: int, msgAway: int): bool {
    return msgHome != oldHome || msgAway != oldAway;
}

fun hasPredictionResultChanged(oldResult: int, newResult: int): bool {
    return oldResult != newResult;
}

fun validateProposedResult(storage: Storage, msg: MsgProposeResult) {
    if (storage.market == 0) {
        assert(msg.predictionResult == 0) throw ERR_WRONG_STATE;
        // void = оба счёта -1; частичный -1 (один -1, другой нет) — невалидный void
        assert((msg.scoreHome == -1) == (msg.scoreAway == -1)) throw ERR_WRONG_STATE;
        return;
    }
    assert(msg.predictionResult != 0) throw ERR_WRONG_STATE;
}

fun validateResolvedResult(storage: Storage, msg: MsgOracleResolve) {
    if (storage.market == 0) {
        assert(msg.predictionResult == 0) throw ERR_WRONG_STATE;
        assert((msg.scoreHome == -1) == (msg.scoreAway == -1)) throw ERR_WRONG_STATE;
        return;
    }
    assert(msg.predictionResult != 0) throw ERR_WRONG_STATE;
}

fun doSettleByResult(storage: Storage, deal: DealData) {
    if (storage.market == 0) {
        doSettleSport(deal, storage.scoreHome as int, storage.scoreAway as int, storage.dealsCount as int);
        return;
    }
    doSettlePrediction(deal, storage.predictionResult as int, storage.dealsCount as int);
}

// --- ТОЧКА ВХОДА ---

fun onInternalMessage(in: InMessage) {
    val sender = in.senderAddress;

    // Пустое тело = депозит TON (пинг активации от exchange).
    if (in.body.isEmpty()) {
        var storage = Storage.load();
        val actors = loadActors(storage);
        assert(actors.oracle != actors.exchange) throw ERR_INVALID_CONFIG;
        if (sender == actors.exchange && in.valueCoins < DEPLOY_THRESHOLD) {
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: sender,
                value: 0,
                body: beginCell().endCell(),
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        return;
    }

    val op = in.body.preloadUint(32);
    var bodySlice = in.body;

    // Текстовый комментарий (op==0) — деплой или пополнение.
    if (op == 0) {
        var storage = Storage.load();
        val actors = loadActors(storage);
        assert(actors.oracle != actors.exchange) throw ERR_INVALID_CONFIG;
        if (sender == actors.exchange && in.valueCoins < DEPLOY_THRESHOLD) {
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: sender,
                value: 0,
                body: beginCell().endCell(),
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        return;
    }

    // --- 0x105: DepositForDeal (от vault-контракта) ---
    if (op == 0x105) {
        val msg = MsgDepositForDeal.fromSlice(bodySlice);

        var storage = Storage.load();
        var dealOpt = storage.deals.get(msg.dealId);

        var deal: DealData;
        var amounts: DealAmounts;
        if (!dealOpt.isFound) {
            assert(msg.dealId > 0) throw ERR_INVALID_DEAL_ID;
            amounts = DealAmounts {
                amountBuy: msg.amountBuy,
                amountSell: msg.amountSell,
                depositedBuy: 0,
                depositedSell: 0,
            };
            deal = DealData {
                userBuy: msg.vaultBuy,
                userSell: msg.vaultSell,
                betType: msg.betType,
                betParam: msg.betParam,
                amounts: amounts.toCell(),
            };
            storage.dealsCount += 1;
        } else {
            deal = dealOpt.loadValue();
            amounts = DealAmounts.fromCell(deal.amounts);
        }

        var funded = false;
        if (sender == deal.userBuy) {
            amounts.depositedBuy += in.valueCoins;
        } else if (sender == deal.userSell) {
            amounts.depositedSell += in.valueCoins;
        } else {
            throw ERR_NOT_PARTICIPANT;
        }

        if (amounts.depositedBuy + DEPOSIT_TOLERANCE >= amounts.amountBuy &&
            amounts.depositedSell + DEPOSIT_TOLERANCE >= amounts.amountSell) {
            funded = true;
        }

        deal.amounts = amounts.toCell();
        storage.deals.set(msg.dealId, deal);
        storage.save();

        if (funded) {
            val actors = loadActors(storage);
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: actors.exchange,
                value: 0,
                body: beginCell()
                    .storeUint(0x110, 32)
                    .storeUint(msg.dealId, 64)
                .endCell(),
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);
        }
        return;
    }

    // --- 0x600: ProposeResult (только exchange; PENDING или PROPOSED без Challenge) ---
    if (op == 0x600) {
        val msg = MsgProposeResult.fromSlice(bodySlice);

        var storage = Storage.load();
        val actors = loadActors(storage);
        assert(sender == actors.exchange) throw ERR_EXCHANGE_ONLY;
        assert(storage.resultState == RS_PENDING || storage.resultState == RS_PROPOSED) throw ERR_WRONG_STATE;
        validateProposedResult(storage, msg);

        // Сбрасываем окно оспаривания только при изменении результата (Вариант B).
        // Re-propose с тем же результатом не продлевает challenge window —
        // иначе exchange мог бы откладывать выплаты бесконечно.
        val resultChanged = (storage.resultState == RS_PENDING) || (
            (storage.market == 0)
            ? hasSportsResultChanged(storage.scoreHome as int, storage.scoreAway as int, msg.scoreHome as int, msg.scoreAway as int)
            : hasPredictionResultChanged(storage.predictionResult as int, msg.predictionResult as int)
        );

        storage.resultState = RS_PROPOSED;
        storage.scoreHome = msg.scoreHome;
        storage.scoreAway = msg.scoreAway;
        storage.predictionResult = msg.predictionResult;
        if (resultChanged) {
            storage.proposedAt = blockchain.now();
        }
        storage.save();

        createMessage({
            bounce: BounceMode.NoBounce,
            dest: sender,
            value: 0,
            body: beginCell().endCell(),
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    // --- 0x601: Challenge (участник сделки; только PROPOSED + в пределах окна; value == 10 TON) ---
    if (op == 0x601) {
        val msg = MsgChallenge.fromSlice(bodySlice);

        var storage = Storage.load();
        var actors = loadActors(storage);
        assert(storage.resultState == RS_PROPOSED) throw ERR_WRONG_STATE;
        assert(blockchain.now() <= (storage.proposedAt + getChallengePeriod(storage.eventType))) throw ERR_CHALLENGE_PERIOD_OVER;
        assert(in.valueCoins >= DISPUTE_DEPOSIT) throw ERR_DISPUTE_DEPOSIT_WRONG;

        val dealOpt = storage.deals.get(msg.dealId);
        assert(dealOpt.isFound) throw ERR_DEAL_NOT_FOUND;
        val deal = dealOpt.loadValue();
        assert(sender == deal.userBuy || sender == deal.userSell) throw ERR_NOT_PARTICIPANT;

        storage.resultState = RS_DISPUTED;
        storage.challengedAt = blockchain.now();
        actors.challenger = sender;
        saveActors(storage, actors);
        storage.save();

        // Уведомляем exchange: ChallengeRaised (0x111) → scanner → ton-challenge-queue
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: actors.exchange,
            value: 0,
            body: beginCell()
                .storeUint(0x111, 32)
                .storeUint(msg.dealId, 64)
                .storeAddress(sender)
            .endCell(),
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);
        return;
    }

    // --- 0x602: OracleResolve (только oracle; только DISPUTED) ---
    if (op == 0x602) {
        val msg = MsgOracleResolve.fromSlice(bodySlice);

        var storage = Storage.load();
        var actors = loadActors(storage);
        assert(sender == actors.oracle) throw ERR_ORACLE_ONLY;
        assert(storage.resultState == RS_DISPUTED) throw ERR_WRONG_STATE;
        validateResolvedResult(storage, msg);

        // Если Oracle меняет предложенный результат → вернуть депозит challenger'у (был прав)
        val resultChanged =
            (storage.market == 0)
            ? hasSportsResultChanged(storage.scoreHome as int, storage.scoreAway as int, msg.scoreHome as int, msg.scoreAway as int)
            : hasPredictionResultChanged(storage.predictionResult as int, msg.predictionResult as int);
        if (resultChanged) {
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: actors.challenger,
                value: DISPUTE_DEPOSIT,
                body: beginCell().endCell(),
            }).send(SEND_MODE_REGULAR);
        }
        // Если Oracle подтверждает счёт → депозит остаётся в контракте (coniscated fee)

        storage.resultState = RS_RESOLVED;
        storage.scoreHome = msg.scoreHome;
        storage.scoreAway = msg.scoreAway;
        storage.predictionResult = msg.predictionResult;
        storage.save();

        // Уведомляем exchange: OracleResolved (0x112) → scanner → status=6
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: actors.exchange,
            value: 0,
            body: beginCell()
                .storeUint(0x112, 32)
                .storeInt(msg.scoreHome, 16)
                .storeInt(msg.scoreAway, 16)
                .storeUint(msg.predictionResult, 2)
            .endCell(),
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);

        createMessage({
            bounce: BounceMode.NoBounce,
            dest: sender,
            value: 0,
            body: beginCell().endCell(),
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    // --- 0x700: Settle (permissionless) ---
    if (op == 0x700) {
        val msg = MsgSettle.fromSlice(bodySlice);

        var storage = Storage.load();

        val dealOpt = storage.deals.get(msg.dealId);
        assert(dealOpt.isFound) throw ERR_DEAL_NOT_FOUND;
        val deal = dealOpt.loadValue();

        if (storage.resultState == RS_PENDING) {
            // Emergency: exchange не предложил результат спустя DISPUTE_EMERGENCY после старта — возврат средств
            assert(blockchain.now() >= storage.startTime + DISPUTE_EMERGENCY) throw ERR_RESULT_NOT_SET;
            doRefund(deal);
        } else if (storage.resultState == RS_PROPOSED) {
            assert(blockchain.now() > (storage.proposedAt + getChallengePeriod(storage.eventType))) throw ERR_NOT_SETTLEABLE;
            doSettleByResult(storage, deal);
        } else if (storage.resultState == RS_DISPUTED) {
            assert(blockchain.now() >= (storage.challengedAt + DISPUTE_EMERGENCY)) throw ERR_NOT_SETTLEABLE;
            doRefund(deal);
        } else { // RS_RESOLVED
            doSettleByResult(storage, deal);
        }

        storage.deals.delete(msg.dealId);
        storage.save();

        if (storage.deals.isEmpty()) {
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: loadActors(storage).exchange,
                value: 0,
                body: beginCell().storeUint(0, 32).storeSlice("Deals processed, contract deactivated").endCell(),
            }).send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_DESTROY);
        } else {
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: sender,
                value: 0,
                body: beginCell().endCell(),
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        return;
    }

    // --- 0x500: WithdrawFees ---
    if (op == 0x500) {
        var storage = Storage.load();
        val actors = loadActors(storage);
        assert(sender == actors.exchange) throw ERR_EXCHANGE_ONLY;
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: actors.exchange,
            value: 0,
            body: beginCell().storeUint(0, 32).storeSlice("Fees withdrawn, contract deactivated").endCell(),
        }).send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_DESTROY);
        return;
    }

    // --- 0xdeadbeef: DeactivateAndWithdraw ---
    if (op == 0xdeadbeef) {
        var storage = Storage.load();
        val actors = loadActors(storage);
        assert(sender == actors.exchange) throw ERR_EXCHANGE_ONLY_DEACTIVATE;
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: actors.exchange,
            value: 0,
            body: beginCell().storeUint(0, 32).storeSlice("Emergency deactivation, contract destroyed").endCell(),
        }).send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_DESTROY);
        return;
    }

    throw 0xffff;
}

// --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

fun doSettleSport(deal: DealData, scoreHome: int, scoreAway: int, dealsCount: int) {
    // void (аннулирование события) → возврат обоим
    if (scoreHome == -1 && scoreAway == -1) {
        doRefund(deal);
        return;
    }
    val outcome = isWinForBuy(deal.betType as int, deal.betParam as int, scoreHome, scoreAway, 0);
    if (outcome == -1) { // push
        doRefund(deal);
        return;
    }
    doPayout(deal, outcome, dealsCount);
}

fun doSettlePrediction(deal: DealData, predictionResult: int, dealsCount: int) {
    if (predictionResult == 3) {
        doRefund(deal);
        return;
    }
    val outcome = isWinForBuy(deal.betType as int, deal.betParam as int, 0, 0, predictionResult);
    if (outcome == -1) { // push
        doRefund(deal);
        return;
    }
    doPayout(deal, outcome, dealsCount);
}

fun doPayout(deal: DealData, outcome: int, dealsCount: int) {
    val amounts = DealAmounts.fromCell(deal.amounts);
    val winner = (outcome == 1) ? deal.userBuy : deal.userSell;
    val winnerDeposit: int = (outcome == 1) ? amounts.depositedBuy : amounts.depositedSell;
    val profit: int = (outcome == 1) ? amounts.depositedSell : amounts.depositedBuy;
    val deployShare: int = DEPLOY_FEE / dealsCount;
    val fee: int = profit * EXCHANGE_FEE_PCT / 100 + deployShare + TRANSFER_GAS_FEE;
    val sendAmount: int = winnerDeposit + profit - fee;
    createMessage({
        bounce: BounceMode.NoBounce,
        dest: winner,
        value: sendAmount,
        body: beginCell().endCell(),
    }).send(SEND_MODE_REGULAR);
}

// Вернуть депозиты обоим участникам пропорционально (логика аналогична старому CancelSingle)
fun doRefund(deal: DealData) {
    val amounts = DealAmounts.fromCell(deal.amounts);
    val totalDeposited: int = amounts.depositedBuy + amounts.depositedSell;
    if (totalDeposited > 0) {
        val feeBuy: int = TRANSFER_GAS_FEE * amounts.depositedBuy / totalDeposited;
        val feeSell: int = TRANSFER_GAS_FEE - feeBuy;
        val sendBuy: int = amounts.depositedBuy - feeBuy;
        val sendSell: int = amounts.depositedSell - feeSell;
        if (sendBuy > 0) {
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: deal.userBuy,
                value: sendBuy,
                body: beginCell().endCell(),
            }).send(SEND_MODE_REGULAR);
        }
        if (sendSell > 0) {
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: deal.userSell,
                value: sendSell,
                body: beginCell().endCell(),
            }).send(SEND_MODE_REGULAR);
        }
    }
}

// --- ГЕТТЕРЫ ---

get fun deal(dealId: int): DealData? {
    val storage = Storage.load();
    val r = storage.deals.get(dealId as uint64);
    if (r.isFound) {
        return r.loadValue();
    }
    return null;
}

get fun count(): int {
    val storage = Storage.load();
    return storage.dealsCount;
}

get fun startTime(): int {
    val storage = Storage.load();
    return storage.startTime;
}

get fun market(): int {
    val storage = Storage.load();
    return storage.market;
}

get fun resultState(): int {
    val storage = Storage.load();
    return storage.resultState;
}

get fun proposedScore(): (int, int) {
    val storage = Storage.load();
    return (storage.scoreHome, storage.scoreAway);
}

get fun proposedPredictionResult(): int {
    val storage = Storage.load();
    return storage.predictionResult;
}

get fun challengeDeadline(): int {
    val storage = Storage.load();
    if (storage.resultState != RS_PROPOSED) { return 0; }
    return storage.proposedAt + getChallengePeriod(storage.eventType);
}

get fun disputeEmergencyDeadline(): int {
    val storage = Storage.load();
    if (storage.resultState != RS_DISPUTED) { return 0; }
    return storage.challengedAt + DISPUTE_EMERGENCY;
}
