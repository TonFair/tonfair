tolk 1.2

// ============================================================
// vault.tolk — контракт Vault (Tolk 1.2)
//
// Персональное хранилище пользователя на TON.
// Один контракт = один пользователь. Деплоится бэкендом
// при регистрации пользователя на бирже.
//
// Жизненный цикл:
//   1. Деплой (оператор отправляет ~0.05 TON + stateInit)
//   2. Пополнение: пользователь отправляет TON на адрес vault
//   3. Матчинг ставок: оператор вызывает TransferToDeal (0x04) —
//      vault перечисляет средства на контракт события (event_pool)
//   4. Выплата: event_pool отправляет выигрыш обратно на vault
//   5. Вывод: пользователь инициирует вывод (1 час блокировки),
//      затем забирает средства на свой кошелёк
//
// Безопасность:
//   - Только owner может инициировать/выполнить/отменить вывод
//   - Только operator может переводить средства в сделки
//   - При запросе вывода trading отключается (isTradingActive = false),
//     чтобы биржа успела закрыть открытые ордера
// ============================================================

// --- КОНСТАНТЫ ---

// Блокировка вывода: 5 минут (тестовый интервал, перед продом вернуть 3600).
const WITHDRAWAL_LOCK: int = 300;

// Газовый буфер для исходящих сообщений. Покрывает стоимость
// пересылки и обработки сообщений в event_pool.
const GAS_BUFFER: int = ton("0.05");

// --- КОДЫ ОШИБОК (диапазон 2xx, не пересекается с event_pool 1xx) ---

const ERR_OWNER_ONLY: int = 201;             // операция только для владельца
const ERR_OPERATOR_ONLY: int = 202;          // операция только для оператора
const ERR_TRADING_DISABLED: int = 203;       // торговля отключена (вывод запрошен)
const ERR_TOO_EARLY: int = 204;              // таймер вывода ещё не истёк
const ERR_NO_PENDING_WITHDRAWAL: int = 205;  // нет активного запроса на вывод
// ERR_INSUFFICIENT_BALANCE (206) не используется: проверка выполняется на стороне оператора
// перед вызовом TransferToDeal. TVM откатит транзакцию при нехватке газа автоматически.
const ERR_CHALLENGE_TOO_SOON: int = 207;  // кулдаун между Challenge ещё не истёк

// --- СООБЩЕНИЯ (входящие команды с opcode-префиксами) ---

// 0x01: Инициировать вывод. Только owner.
// Устанавливает 1-часовой таймер и отключает trading.
struct (0x01) MsgInitWithdrawal {}

// 0x02: Выполнить вывод. Только owner, после истечения таймера.
// amount = 0 → вывести весь баланс (vault остаётся живым с нулевым балансом).
// amount > 0 → вывести указанную сумму, остаток остаётся на vault, торговля возобновляется.
struct (0x02) MsgExecuteWithdrawal {
    amount: coins   // 0 = вывести всё
}

// 0x03: Отменить запрос на вывод. Только owner.
// Сбрасывает таймер и восстанавливает торговлю.
struct (0x03) MsgCancelWithdrawal {}

// 0x04: Перевести средства в контракт сделки. Только exchange (оператор).
// Работает только при isTradingActive = true.
// Адреса (dealContract, vaultBuy, vaultSell) вынесены в ref-ячейку DealAddresses,
// чтобы основная ячейка вмещала данные при любых суммах ставок:
//   opcode(8) + amount + dealId(64) + amountBuy + amountSell + betType(4) + betParam(64) + ref
//   = ~248 бит для малых сумм (4-байтовые coins) — не переполнится при реальных объёмах.
struct DealAddresses {
    dealContract: address  // адрес EventPool
    vaultBuy: address      // vault-адрес покупателя
    vaultSell: address     // vault-адрес продавца
}

struct (0x04) MsgTransferToDeal {
    amount: coins
    dealId: uint64
    amountBuy: coins       // ставка покупателя (для создания сделки)
    amountSell: coins      // ставка продавца (для создания сделки)
    betType: uint4         // тип ставки (0–8)
    betParam: uint64       // параметр ставки / market id для prediction
    addrs: cell            // ref: DealAddresses
}

// 0x05: Экстренный вывод оператором. Только exchange (оператор).
// Отправляет весь баланс на кошелёк owner'а.
// Используется при технических проблемах.
struct (0x05) MsgForceWithdraw {}

// 0x06: Оспорить результат события. Только owner.
// Проксирует Challenge (0x601, 32-бит) на dealContract с DISPUTE_DEPOSIT из баланса vault.
// Кулдаун зависит от типа события: UP_DOWN (101–105) — 5 мин, остальные — 6 ч.
struct (0x06) MsgVaultChallenge {
    dealContract: address
    dealId: uint64
    eventType: uint10  // тип события; определяет длину кулдауна (UP_DOWN vs остальные)
}

// Залог challenger'а — должен совпадать с DISPUTE_DEPOSIT в event_pool.tolk.
const DISPUTE_DEPOSIT: int = ton("0.1");  // todo: вернуть ton("10") перед продом
// Кулдауны между Challenge от одного vault.
// CHALLENGE_COOLDOWN применяется для SPORT/PREDICTION (6 ч).
// CHALLENGE_PERIOD_UPDOWN — для UP_DOWN (101–105), 5 мин: короткое окно, длинный кулдаун бесполезен.
const CHALLENGE_COOLDOWN: int = 21600;
const CHALLENGE_PERIOD_UPDOWN: int = 300;

// Исходящие уведомления vault → exchange (не входящие команды):
// 0x600: owner пополнил vault (scanner → TRADING, обновить баланс)
// 0x601: owner инициировал вывод (scanner → WITHDRAWAL_PENDING, обновить баланс)
// 0x602: вывод выполнен (scanner → TRADING, обновить баланс; balance=0 при полном, >0 при частичном)
// 0x603: сторонний депозит (event_pool выплатил выигрыш и т.п.) — scanner обновляет только баланс

// --- ХРАНИЛИЩЕ ---
// Порядок полей = порядок сериализации в fromInit() (Vault.ts):
//   storeAddress(owner)                — 267 бит
//   storeAddress(exchange)             — 267 бит
//   storeUint(withdrawTimestamp, 32)   — 32 бита (0 = нет запроса)
//   storeBit(isTradingActive)          — 1 бит (true при старте)
//   storeUint(lastChallengeExpiry, 32) — 32 бита (0 = Challenge не было)
struct Storage {
    owner: address             // кошелёк пользователя
    exchange: address          // кошелёк оператора биржи (exchange — не зарезервировано)
    withdrawTimestamp: uint32  // unix-время разблокировки вывода (0 = нет запроса)
    isTradingActive: bool      // разрешён ли перевод в сделки
    lastChallengeExpiry: uint32 // unix timestamp истечения кулдауна после Challenge (0 = не было)
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

// Записывает десятичное число как ASCII-цифры в builder (старший разряд первым, рекурсивно)
fun storeDecimal(b: builder, n: int): builder {
    if (n >= 10) { b = storeDecimal(b, n / 10); }
    return b.storeUint(0x30 + (n % 10), 8);
}

// --- ТОЧКА ВХОДА ---

fun onInternalMessage(in: InMessage) {
    val sender = in.senderAddress;

    // Пустое тело = депозит. Принимаем от кого угодно:
    // - пользователь пополняет vault со своего кошелька
    // - event_pool выплачивает выигрыш на vault победителя
    // - оператор может пополнить vault
    if (in.body.isEmpty()) {
        var storage = Storage.load();
        val isOwner = (sender == storage.owner);

        // Если owner пополняет vault пока вывод pending — автоматически отменяем.
        // Логика: если человек пополняет свой vault, он явно хочет торговать, а не выводить.
        if (isOwner && storage.withdrawTimestamp != 0) {
            storage.withdrawTimestamp = 0;
            storage.isTradingActive = true;
            storage.save();
        }

        // 0x600 — owner deposit (scanner → TRADING, обновить баланс)
        // 0x603 — third-party deposit (event_pool и др.) — scanner обновляет только баланс
        // SEND_MODE_PAY_FEES_SEPARATELY: forward fee берётся из баланса vault автоматически.
        val notifyOp = isOwner ? 0x600 : 0x603;
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: storage.exchange,
            value: 0,
            body: beginCell()
                .storeUint(notifyOp, 32)
                .storeCoins(contract.getOriginalBalance())
            .endCell(),
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);
        return;
    }

    // Tolk struct(0x01..0x05) сериализует opcode как минимальную ширину (8 бит).
    // fromSlice() использует SDBEGINSQ x{NN} — проверяет ровно 8 бит.
    val op = in.body.preloadUint(8);
    var bodySlice = in.body;

    // Standard TON text comment: 0x00000000 (32 bits) + UTF-8.
    // First byte = 0x00 — treat as deposit (e.g. "deposit 10 TON", "vault deploy").
    // Применяем ту же логику owner/third-party что и для пустого тела.
    if (op == 0x00) {
        var storage = Storage.load();
        val isOwner = (sender == storage.owner);

        if (isOwner && storage.withdrawTimestamp != 0) {
            storage.withdrawTimestamp = 0;
            storage.isTradingActive = true;
            storage.save();
        }

        val notifyOp = isOwner ? 0x600 : 0x603;
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: storage.exchange,
            value: 0,
            body: beginCell()
                .storeUint(notifyOp, 32)
                .storeCoins(contract.getOriginalBalance())
            .endCell(),
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);
        return;
    }

    // 0x01 — InitWithdrawal: запросить вывод средств
    if (op == 0x01) {
        var storage = Storage.load();
        assert(sender == storage.owner) throw ERR_OWNER_ONLY;

        // Устанавливаем таймер и блокируем торговлю
        storage.withdrawTimestamp = blockchain.now() + WITHDRAWAL_LOCK;
        storage.isTradingActive = false;
        storage.save();

        // Уведомляем оператора: торговля заблокирована, текущий баланс vault.
        // Opcode 0x601 = VAULT_WITHDRAW_INIT_NOTIFY.
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: storage.exchange,
            value: 0,
            body: beginCell()
                .storeUint(0x601, 32)
                .storeCoins(contract.getOriginalBalance())
            .endCell(),
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);

        // Возвращаем сдачу газа owner'у
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: sender,
            value: 0,
            body: beginCell().endCell(),
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    // 0x02 — ExecuteWithdrawal: выполнить вывод после истечения блокировки
    if (op == 0x02) {
        val msg = MsgExecuteWithdrawal.fromSlice(bodySlice);
        var storage = Storage.load();
        assert(sender == storage.owner) throw ERR_OWNER_ONLY;
        // Проверяем наличие активного запроса
        assert(storage.withdrawTimestamp != 0) throw ERR_NO_PENDING_WITHDRAWAL;
        // Проверяем истечение таймера
        assert(blockchain.now() >= storage.withdrawTimestamp) throw ERR_TOO_EARLY;

        // Сбрасываем состояние ДО отправки (защита от re-entrancy)
        storage.withdrawTimestamp = 0;
        storage.isTradingActive = true;
        storage.save();

        val currentBalance = contract.getOriginalBalance();

        if (msg.amount == 0 || msg.amount >= currentBalance) {
            // Полный вывод: уведомляем с balance=0, отправляем весь баланс owner'у.
            // ВАЖНО: mode 128 БЕЗ флага DESTROY (32) — vault остаётся живым,
            // адрес стабилен для будущих депозитов (выигрышей и пополнений).
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.exchange,
                value: 0,
                body: beginCell()
                    .storeUint(0x602, 32)
                    .storeCoins(0)
                .endCell(),
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);

            createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.owner,
                value: 0,
                body: beginCell().endCell(),
            }).send(SEND_MODE_CARRY_ALL_BALANCE);
        } else {
            // Частичный вывод: отправляем amount owner'у, остаток остаётся для торговли.
            // Уведомляем оператора с приблизительным остатком (точная сумма скорректируется
            // следующим депозитом или запросом состояния).
            val remaining = currentBalance - msg.amount;
            createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.exchange,
                value: 0,
                body: beginCell()
                    .storeUint(0x602, 32)
                    .storeCoins(remaining)
                .endCell(),
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);

            createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.owner,
                value: msg.amount,
                body: beginCell().endCell(),
            }).send(SEND_MODE_REGULAR);
        }
        return;
    }

    // 0x03 — CancelWithdrawal: отменить запрос на вывод
    if (op == 0x03) {
        var storage = Storage.load();
        assert(sender == storage.owner) throw ERR_OWNER_ONLY;
        assert(storage.withdrawTimestamp != 0) throw ERR_NO_PENDING_WITHDRAWAL;

        storage.withdrawTimestamp = 0;
        storage.isTradingActive = true;
        storage.save();

        createMessage({
            bounce: BounceMode.NoBounce,
            dest: sender,
            value: 0,
            body: beginCell().endCell(),
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    // 0x04 — TransferToDeal: перевести средства в контракт события
    if (op == 0x04) {
        val msg = MsgTransferToDeal.fromSlice(bodySlice);
        val addrs = DealAddresses.fromCell(msg.addrs);
        var storage = Storage.load();
        assert(sender == storage.exchange) throw ERR_OPERATOR_ONLY;
        // Вывод запрошен — блокируем переводы в сделки
        assert(storage.isTradingActive) throw ERR_TRADING_DISABLED;
        // Примечание: если на балансе недостаточно средств для покрытия amount + газ,
        // TVM автоматически откатит транзакцию с исключением нехватки газа.
        // Оператор должен проверять баланс vault перед вызовом TransferToDeal.

        // Перечисляем средства на event_pool с opcode DepositForDeal (0x105).
        // event_pool создаст сделку (если ещё не существует) и обновит depositedBuy/depositedSell.
        // При полном финансировании event_pool эмитирует DealFunded (0x110) → оператор.
        // Передаём параметры сделки, чтобы event_pool мог создать её при первом депозите.
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: addrs.dealContract,
            value: msg.amount,
            body: beginCell()
                .storeUint(0x105, 32)
                .storeUint(msg.dealId, 64)
                .storeCoins(msg.amountBuy)
                .storeCoins(msg.amountSell)
                .storeAddress(addrs.vaultBuy)
                .storeAddress(addrs.vaultSell)
                .storeUint(msg.betType, 4)
                .storeUint(msg.betParam, 64)
            .endCell(),
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);

        // Уведомляем owner о матче — сообщение видно в TonKeeper как входящая транзакция.
        // Формат: "Deal #<id> matched: <whole>.<frac> TON"
        // Газ берётся из баланса vault (SEND_MODE_PAY_FEES_SEPARATELY).
        val whole: int = msg.amount / 1000000000;
        val frac: int = (msg.amount % 1000000000) / 10000000; // 2 знака после запятой
        var notifyBody = beginCell().storeUint(0, 32).storeSlice("Deal #");
        notifyBody = storeDecimal(notifyBody, msg.dealId as int);
        notifyBody = notifyBody.storeSlice(" matched: ");
        notifyBody = storeDecimal(notifyBody, whole);
        notifyBody = notifyBody.storeUint(0x2E, 8); // '.'
        if (frac < 10) { notifyBody = notifyBody.storeUint(0x30, 8); } // ведущий ноль
        notifyBody = storeDecimal(notifyBody, frac);
        notifyBody = notifyBody.storeSlice(" TON");
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: storage.owner,
            value: 0,
            body: notifyBody.endCell(),
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);

        // Возвращаем оставшийся газ оператору
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: storage.exchange,
            value: 0,
            body: beginCell().endCell(),
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    // 0x05 — ForceWithdraw: экстренный вывод оператором
    if (op == 0x05) {
        var storage = Storage.load();
        assert(sender == storage.exchange) throw ERR_OPERATOR_ONLY;

        // Восстанавливаем состояние и отправляем всё owner'у
        storage.withdrawTimestamp = 0;
        storage.isTradingActive = true;
        storage.save();

        createMessage({
            bounce: BounceMode.NoBounce,
            dest: storage.owner,
            value: 0,
            body: beginCell().endCell(),
        }).send(SEND_MODE_CARRY_ALL_BALANCE);
        return;
    }

    // 0x06 — VaultChallenge: оспорить результат события через vault
    if (op == 0x06) {
        val msg = MsgVaultChallenge.fromSlice(bodySlice);
        var storage = Storage.load();
        assert(sender == storage.owner) throw ERR_OWNER_ONLY;
        // Кулдаун: для UP_DOWN (101–105) — 5 мин, иначе — 6 ч.
        // Без per-event cooldown, но короткий кулдаун для UP_DOWN сохраняет возможность
        // оспаривать разные события в пределах их 5-минутного окна.
        assert(
            storage.lastChallengeExpiry == 0 ||
            blockchain.now() >= storage.lastChallengeExpiry
        ) throw ERR_CHALLENGE_TOO_SOON;

        val cooldown = (msg.eventType >= 101 && msg.eventType <= 105)
            ? CHALLENGE_PERIOD_UPDOWN
            : CHALLENGE_COOLDOWN;
        storage.lastChallengeExpiry = blockchain.now() + cooldown;
        storage.save();

        // Пересылаем Challenge (0x601, 32-бит opcode) на EventPool с залогом из баланса vault.
        // Only256BitsOfBody: если EventPool отклонит (неверное состояние, истёкшее окно и др.),
        // bounce вернёт DISPUTE_DEPOSIT, а onBouncedMessage сбросит lastChallengeExpiry.
        createMessage({
            bounce: BounceMode.Only256BitsOfBody,
            dest: msg.dealContract,
            value: DISPUTE_DEPOSIT,
            body: beginCell()
                .storeUint(0x601, 32)
                .storeUint(msg.dealId, 64)
            .endCell(),
        }).send(SEND_MODE_PAY_FEES_SEPARATELY);

        // Возвращаем сдачу газа owner'у
        createMessage({
            bounce: BounceMode.NoBounce,
            dest: sender,
            value: 0,
            body: beginCell().endCell(),
        }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    // Неизвестный opcode — отклоняем транзакцию
    throw 0xffff;
}

// --- BOUNCE HANDLER ---

// Обрабатывает отказы от сообщений, отправленных vault'ом с BounceMode != NoBounce.
// Сейчас единственный кандидат: 0x601 Challenge → EventPool.
// Если EventPool отклонил Challenge, сбрасываем lastChallengeExpiry = 0 и возвращаем DISPUTE_DEPOSIT.
fun onBouncedMessage(in: InMessageBounced) {
    var body = in.bouncedBody;
    body.skipBouncedPrefix();
    val origOp = body.loadUint(32);
    if (origOp == 0x601) {
        var storage = Storage.load();
        storage.lastChallengeExpiry = 0; // EventPool отклонил Challenge — снимаем кулдаун
        storage.save();
    }
}

// --- ГЕТТЕРЫ ---

// Вернуть полное состояние vault для off-chain чтения.
// Используется фронтендом для отображения статуса торговли
// и обратного отсчёта до разблокировки вывода.
get fun state(): Storage {
    return Storage.load();
}
