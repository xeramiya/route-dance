import Foundation

/// 1フレーム分の入力（知覚の結果）。画像処理はアプリ層で行い、ここには結果だけを渡す。
public struct PerceptionInput: Sendable {
    public var timestamp: Double
    public var imageWidth: Int
    public var imageHeight: Int
    /// 新しい深度が得られたフレームだけ値を持つ。
    public var depth: DepthMap?
    public var detections: [PersonDetection]?
    /// 地面上の特徴点の対応（前フレーム → 現フレーム、画像のピクセル座標）。
    public var flowPairs: [(previous: SIMD2<Double>, current: SIMD2<Double>)]
    /// ライブのみ: 前フレームからのヨー回転（heading、右回り正、ラジアン）。
    public var gyroYaw: Double?
    /// ライブのみ: 重力方向（カメラ座標、下向き単位ベクトル）。
    public var gravity: SIMD3<Double>?
    /// 動画のメタデータなどから分かる水平画角。
    public var knownHorizontalFOV: Double?

    public init(
        timestamp: Double, imageWidth: Int, imageHeight: Int, depth: DepthMap? = nil,
        detections: [PersonDetection]? = nil, flowPairs: [(previous: SIMD2<Double>, current: SIMD2<Double>)] = [],
        gyroYaw: Double? = nil, gravity: SIMD3<Double>? = nil, knownHorizontalFOV: Double? = nil
    ) {
        self.timestamp = timestamp
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.depth = depth
        self.detections = detections
        self.flowPairs = flowPairs
        self.gyroYaw = gyroYaw
        self.gravity = gravity
        self.knownHorizontalFOV = knownHorizontalFOV
    }
}

/// 描画とHUDに渡す、1フレーム分の結果。
public struct NavigationSnapshot: Sendable {
    public var timestamp: Double
    public var geometry: CameraGeometry
    public var userVelocity: Vec2
    public var userSpeed: Double
    public var egoTracking: Bool
    public var groundConverged: Bool
    public var groundInlierRatio: Double?
    public var odometryInliers: Int
    public var persons: [LocalizedPerson]
    /// このフレームの検出（位置推定できなかったものも含む、描画用）。
    public var detections: [PersonDetection]
    public var tracks: [Track]
    /// 深度から作った静的障害物。
    public var obstacles: ObstacleMap
    public var forecasts: [PedestrianForecast]
    public var plan: PlannerOutput?
    public var riskField: RiskField?
    public var goal: Vec2?
    public var timings: [String: Double]
    public var predictorName: String
}

/// 地面推定 → 自己位置 → 人物の位置 → 追跡 → 予測 → 計画、を順に行う。プラットフォームに依存しない。
public struct NavigationCore: Sendable {
    public struct Config: Sendable {
        public var computeRiskField = true
        public var planEveryFrame = true
        public init() {}
    }

    public var config: Config
    public var ground = GroundEstimator()
    public var ego = EgoMotionEstimator()
    public var localizer = PersonLocalizer()
    public var tracker = PedestrianTracker()
    public var predictor: any TrajectoryPredictor = ConstantVelocityPredictor()
    public var planner = PathPlanner()
    public var goalProvider: any GoalProvider = DeviceForwardGoal()

    private var camera: PinholeCamera?
    private var fovSmoother = ExponentialSmoother(tau: 2.0)
    private var latestDepth: DepthMap?
    private var previousGeometry: CameraGeometry?
    private var lastPersons: [LocalizedPerson] = []
    private var lastDetections: [PersonDetection] = []
    public var obstacleBuilder = ObstacleMapBuilder()
    private var obstacles = ObstacleMap.empty

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        ground.reset()
        ego.reset()
        tracker.reset()
        planner.reset()
        camera = nil
        fovSmoother.reset()
        latestDepth = nil
        previousGeometry = nil
        lastPersons = []
        lastDetections = []
        obstacles = .empty
        obstacleBuilder.reset()
    }

    public mutating func process(_ input: PerceptionInput) -> NavigationSnapshot {
        var timings: [String: Double] = [:]
        func measure<T>(_ name: String, _ body: () -> T) -> T {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = body()
            timings[name] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return r
        }
        let t = input.timestamp

        // カメラ（画角）: 既知ならそれを使い、なければ深度モデルの推定値を平滑化する。
        if let g = input.gravity { ground.update(gravity: g, at: t) }
        var frameGround: GroundPlane?
        if let d = input.depth {
            latestDepth = d
            let fov = input.knownHorizontalFOV ?? fovSmoother.update(d.camera.horizontalFOV, at: t)
            if camera == nil, input.knownHorizontalFOV == nil {
                // 仮の画角で作ったトラックは位置がずれているので、最初の推定で作り直す。
                tracker.reset()
                previousGeometry = nil
            }
            camera = PinholeCamera(horizontalFOV: fov, width: input.imageWidth, height: input.imageHeight)
            let w = Double(input.imageWidth), h = Double(input.imageHeight)
            let boxes: [PersonDetection] = input.detections ?? lastPersons.map(\.detection)
            let exclude: [(Double, Double, Double, Double)] = boxes.map { b in
                (b.minX / w, b.minY / h, b.maxX / w, b.maxY / h)
            }
            frameGround = measure("ground") {
                ground.update(points: d.groundCandidatePoints(excluding: exclude), at: t)?.plane
            }
        }
        let camForObstacles = camera ?? PinholeCamera(
            horizontalFOV: input.knownHorizontalFOV ?? 65 * .pi / 180, width: input.imageWidth, height: input.imageHeight
        )
        if let d = input.depth {
            // 障害物は、同じフレームの深度に当てはめた地面で判定する。時間方向に平滑化した地面は
            // その深度のスケールや傾きとずれるので、平らな地面まで障害物に見えてしまう。
            // 地面が当てはまらなかったフレームは判定しない（前の地図を自己運動で動かして使う）。
            if let plane = frameGround {
                let g = CameraGeometry(camera: camForObstacles, ground: plane)
                let boxes: [PersonDetection] = input.detections ?? lastDetections
                obstacles = measure("obstacles") {
                    obstacleBuilder.update(depth: d, geometry: g, excluding: boxes, imageWidth: input.imageWidth, imageHeight: input.imageHeight, at: t)
                }
            }
        }
        let cam = camera ?? PinholeCamera(
            horizontalFOV: input.knownHorizontalFOV ?? 65 * .pi / 180, width: input.imageWidth, height: input.imageHeight
        )
        let geometry = CameraGeometry(camera: cam, ground: ground.current)

        // 自己位置: 前フレームの地面と今のフレームの地面にそれぞれ投影して対応を作る。
        var delta: Pose2D?
        var odoInliers = 0
        if let prevG = previousGeometry, !input.flowPairs.isEmpty {
            measure("odometry") {
                var pairs: [GroundOdometry.Correspondence] = []
                pairs.reserveCapacity(input.flowPairs.count)
                for f in input.flowPairs {
                    guard let a = prevG.intersectGround(u: f.previous.x, v: f.previous.y, maxDistance: 12),
                          let b = geometry.intersectGround(u: f.current.x, v: f.current.y, maxDistance: 12)
                    else { continue }
                    pairs.append(.init(previous: a, current: b))
                }
                if let r = GroundOdometry.estimate(pairs, rotationHint: input.gyroYaw) {
                    delta = r.transform
                    odoInliers = r.inlierCount
                }
            }
        }
        previousGeometry = geometry
        let egoState = ego.update(delta, at: t)
        // 画像オドメトリが失敗したフレームは、ジャイロの回転と直前の速度で外挿する。
        let dt = egoState.lastFrameInterval
        let egoDelta = delta ?? Pose2D(rotation: input.gyroYaw ?? 0, translation: -egoState.velocity * dt)

        // 人物の位置と追跡。検出がないフレームは予測だけ進める。
        var persons = lastPersons
        if let dets = input.detections {
            persons = measure("localize") {
                dets.compactMap { localizer.localize($0, geometry: geometry, depth: latestDepth) }
            }
            lastPersons = persons
        }
        if let dets = input.detections { lastDetections = dets }
        obstacles = obstacleBuilder.transform(obstacles, by: egoDelta)
        measure("track") {
            _ = tracker.update(persons: input.detections == nil ? [] : persons, egoDelta: egoDelta, at: t)
            tracker.updatePredictedBoxes(geometry: geometry)
        }
        let active = tracker.activeTracks

        let forecasts = measure("predict") {
            predictor.predict(tracks: active, userVelocity: egoState.velocity, duration: planner.config.horizon + 0.5)
        }

        // ゴール（端末の向きの最奥）と計画。
        let depthForGoal = latestDepth
        let geometryForGoal = geometry
        let goal = goalProvider.goal(context: GoalContext(deviceHeading: 0) { heading in
            depthForGoal?.farthestVisibleGround(heading: heading, geometry: geometryForGoal)
        })
        let plan = measure("plan") {
            planner.plan(forecasts: forecasts, userVelocity: egoState.velocity, goal: goal, obstacles: obstacles, time: t)
        }
        var field: RiskField?
        if config.computeRiskField {
            field = measure("riskField") {
                RiskField.compute(
                    grid: ForecastGrid(forecasts: forecasts, dt: planner.config.dt, duration: planner.config.horizon),
                    model: planner.collision, speed: plan.planningSpeed
                )
            }
        }

        return NavigationSnapshot(
            timestamp: t, geometry: geometry, userVelocity: egoState.velocity, userSpeed: egoState.speed,
            egoTracking: egoState.isTracking, groundConverged: ground.isConverged,
            groundInlierRatio: ground.lastObservation?.inlierRatio, odometryInliers: odoInliers,
            persons: persons, detections: lastDetections, tracks: tracker.tracks, obstacles: obstacles, forecasts: forecasts, plan: plan, riskField: field,
            goal: goal, timings: timings, predictorName: predictor.name
        )
    }
}
