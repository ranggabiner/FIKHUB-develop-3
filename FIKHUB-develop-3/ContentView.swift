//
//  ContentView.swift
//  FIKHUB-develop-2
//
//  Created by Rangga Biner on 07/09/24.
//

import Foundation
import SwiftData
import SwiftUI
import OpenAI

@main
struct FIKHUB_DevelopApp: App {
    let container: ModelContainer
    let repository: UserRepository
    let saveUserProfileUseCase: SaveUserProfileUseCase
    let getLatestUserProfileUseCase: GetLatestUserProfileUseCase
    
    @StateObject private var profileViewModel: ProfileViewModel
    
    init() {
        do {
            container = try ModelContainer(for: UserStorage.self)
            let context = ModelContext(container)
            repository = SwiftDataUserRepository(context: context)
            saveUserProfileUseCase = SaveUserProfileUseCaseImpl(repository: repository)
            getLatestUserProfileUseCase = GetLatestUserProfileUseCaseImpl(repository: repository)
            
            let viewModel = ProfileViewModel(
                saveUserProfileUseCase: saveUserProfileUseCase,
                getLatestUserProfileUseCase: getLatestUserProfileUseCase
            )
            _profileViewModel = StateObject(wrappedValue: viewModel)
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(profileViewModel: profileViewModel)
        }
    }
}

struct ContentView: View {
    @ObservedObject var profileViewModel: ProfileViewModel

    var body: some View {
        Group {
            if !profileViewModel.isOnboardingCompleted {
                ProfileFormView(viewModel: profileViewModel)
            } else if !profileViewModel.isInitScheduleCompleted {
                InitScheduleView(viewModel: profileViewModel)
            } else {
                MainTabView(profileViewModel: profileViewModel)
            }
        }
        .onAppear {
            profileViewModel.loadLatestUser()
        }
    }
}

//manager
public class SwiftDataManager {
    public static var shared = SwiftDataManager()
    var container: ModelContainer?
    var context: ModelContext?

    init() {
        do {
            container = try ModelContainer(for: UserStorage.self)
            if let container {
                context = ModelContext(container)
            }
        } catch {
            debugPrint("Error initializing database container:", error)
        }
    }
}

//storage
@Model
class UserStorage {
    var id: UUID
    var onboarding: OnboardingModel
    var subjects: [String] // Tambahkan ini

    init(id: UUID, onboarding: OnboardingModel, subjects: [String] = []) {
        self.id = id
        self.onboarding = onboarding
        self.subjects = subjects
    }

    func toDomain() -> UserModel {
        return .init(
            id: self.id,
            onboarding: self.onboarding,
            subjects: self.subjects // Tambahkan ini
        )
    }
}

// repository
protocol UserRepository {
    func saveUser(_ user: UserModel) throws
    func getUser(by id: UUID) throws -> UserModel?
    func getLatestUser() throws -> UserModel?

}

class SwiftDataUserRepository: UserRepository {
    private let context: ModelContext
    
    init(context: ModelContext) {
        self.context = context
    }
    
    func saveUser(_ user: UserModel) throws {
        let userStorage = UserStorage(id: user.id, onboarding: user.onboarding, subjects: user.subjects)
        context.insert(userStorage)
        try context.save()
    }

    func getUser(by id: UUID) throws -> UserModel? {
        let descriptor = FetchDescriptor<UserStorage>(predicate: #Predicate { $0.id == id })
        let result = try context.fetch(descriptor)
        return result.first?.toDomain()
    }
    
    func getLatestUser() throws -> UserModel? {
        var descriptor = FetchDescriptor<UserStorage>(sortBy: [SortDescriptor(\.id, order: .reverse)])
        descriptor.fetchLimit = 1
        let result = try context.fetch(descriptor)
        return result.first?.toDomain()
    }

}

//usecase

protocol SaveUserProfileUseCase {
    func execute(name: String, prodi: String, semester: String, subjects: [String]) throws
}

class SaveUserProfileUseCaseImpl: SaveUserProfileUseCase {
    private let repository: UserRepository

    init(repository: UserRepository) {
        self.repository = repository
    }

    func execute(name: String, prodi: String, semester: String, subjects: [String]) throws {
        let onboarding = OnboardingModel(name: name, prodi: prodi, semester: semester)
        let user = UserModel(id: UUID(), onboarding: onboarding, subjects: subjects)
        try repository.saveUser(user)
    }
}

protocol GetLatestUserProfileUseCase {
    func execute() throws -> UserModel?
}

class GetLatestUserProfileUseCaseImpl: GetLatestUserProfileUseCase {
    private let repository: UserRepository
    
    init(repository: UserRepository) {
        self.repository = repository
    }
    
    func execute() throws -> UserModel? {
        return try repository.getLatestUser()
    }
}

class ChatController: ObservableObject {
    @Published var messages: [ChatMessage] = []
    let openAI = OpenAI(apiToken: "secret api")
    let initialPrompt: String
    let meetingTitle: String
    let profileViewModel: ProfileViewModel
    @Published var isLoading: Bool = false
    
    init(initialPrompt: String, initialMessage: String, meetingTitle: String, profileViewModel: ProfileViewModel) {
        self.initialPrompt = initialPrompt
        self.meetingTitle = meetingTitle
        self.profileViewModel = profileViewModel
        
        if let history = profileViewModel.getChatHistory(for: meetingTitle) {
            self.messages = history.messages
        } else {
            let initialBotMessage = ChatMessage(content: initialMessage, isUser: false)
            self.messages.append(initialBotMessage)
        }
    }
    
    func sendNewMessage(content: String) {
        let userMessage = ChatMessage(content: content, isUser: true)
        self.messages.append(userMessage)
        saveChatHistory()
        
        let loadingMessage = ChatMessage(content: "Loading...", isUser: false)
        self.messages.append(loadingMessage)
        isLoading = true
        getBotReply()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    func getBotReply() {
        let combinedMessages = [ChatMessage(content: initialPrompt, isUser: false)] + self.messages
        let query = ChatQuery(
            messages: combinedMessages.map({ .init(role: $0.isUser ? .user : .system, content: $0.content)! }),
            model: .gpt4_o_mini
        )
        
        openAI.chats(query: query) { result in
            switch result {
            case .success(let success):
                guard let choice = success.choices.first, let message = choice.message.content?.string else { return }
                DispatchQueue.main.async {
                    self.messages.removeLast()
                    self.messages.append(ChatMessage(content: message, isUser: false))
                    self.saveChatHistory()
                    self.isLoading = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            case .failure(let failure):
                print(failure)
                DispatchQueue.main.async {
                    self.messages.removeLast()
                    self.isLoading = false
                }
            }
        }
    }
    
    private func saveChatHistory() {
        let history = ChatHistory(id: UUID(), meetingTitle: meetingTitle, messages: messages)
        profileViewModel.saveChatHistory(history)
    }
}



//models
struct UserModel: Identifiable {
    var id: UUID
    var onboarding: OnboardingModel
    var subjects: [String]

}

struct OnboardingModel: Codable {
    var name: String = ""
    var prodi: String = ""
    var semester: String = ""
}

struct IdentifiableError: Identifiable {
    let id = UUID()
    let error: Error
}

struct ScheduleItem: Identifiable, Codable {
    let id: UUID
    var subject: String
    var location: String
    var day: String
    var startTime: Date
    var endTime: Date
}

struct Meeting: Identifiable, Codable {
    var id = UUID()
    let title: String
    let subject: String
    let description: String
    let initialPrompt: String
    let initialMessage: String
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    let content: String
    let isUser: Bool
    
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.id == rhs.id && lhs.content == rhs.content && lhs.isUser == rhs.isUser
    }
}
struct ChatHistory: Codable, Identifiable {
    let id: UUID
    let meetingTitle: String
    var messages: [ChatMessage]
}

//components
struct TextFieldClear: View {
    let placeholder: String
    @Binding var text: String
    let keyboardType: UIKeyboardType
    let onClear: (() -> Void)?
    
    var body: some View {
        VStack {
            HStack {
                TextField(placeholder, text: $text)
                    .textFieldStyle(DefaultTextFieldStyle())
                    .autocapitalization(.none)
                    .keyboardType(keyboardType)
                
                if !text.isEmpty && onClear != nil {
                    Button(action: {
                        onClear?()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .font(.body)
        }

        
    }
}

struct ButtonFill: View {
    let title: String
    let action: () -> Void
    let backgroundColor: Color
    let foregroundColor: Color
    let height: CGFloat
    let cornerRadius: CGFloat
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    
    init(
        title: String,
        action: @escaping () -> Void,
        backgroundColor: Color = .orange,
        foregroundColor: Color = .white,
        height: CGFloat = 50,
        cornerRadius: CGFloat = 12,
        fontSize: CGFloat = 17,
        fontWeight: Font.Weight = .regular
    ) {
        self.title = title
        self.action = action
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.height = height
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
        self.fontWeight = fontWeight
    }
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, maxHeight: height)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .foregroundColor(foregroundColor)
                .font(.system(size: fontSize, weight: fontWeight))
        }
    }
}

struct ListItem: Identifiable {
    let id = UUID()
    var title: String
    var room: String
    var startTime: String
    var endTime: String
}

//extension
extension ProfileViewModel {
    func dayName(for date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "id_ID")
        dateFormatter.dateFormat = "EEEE"
        return dateFormatter.string(from: date)
    }
}

// viewmodels
class ProfileViewModel: ObservableObject {
    private let saveUserProfileUseCase: SaveUserProfileUseCase
    @Published var error: IdentifiableError?
    private let getLatestUserProfileUseCase: GetLatestUserProfileUseCase
    @Published var savedUser: UserModel?
    @Published var shouldNavigateToSchedule: Bool = false
    @Published var shouldNavigateToHome: Bool = false
    @Published var schedules: [ScheduleItem] = []
    @Published var meetings: [Meeting] = []
    
    @Published var name: String = ""
    @Published var selectedSemester: String = "Pilih Semester"
    @Published var isSaving: Bool = false
    @Published var isOnboardingCompleted: Bool {
        didSet {
            UserDefaults.standard.set(isOnboardingCompleted, forKey: "isOnboardingCompleted")
        }
    }
    @Published var isInitScheduleCompleted: Bool {
        didSet {
            UserDefaults.standard.set(isInitScheduleCompleted, forKey: "isInitScheduleCompleted")
        }
    }
    @Published var subjects: [String] = []
    let dayOrder = ["Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"]

    var sortedSchedules: [ScheduleItem] {
        schedules.sorted { (item1, item2) -> Bool in
            if let index1 = dayOrder.firstIndex(of: item1.day),
               let index2 = dayOrder.firstIndex(of: item2.day) {
                if index1 == index2 {
                    // Jika hari sama, urutkan berdasarkan waktu mulai
                    return item1.startTime < item2.startTime
                }
                // Jika hari berbeda, urutkan berdasarkan urutan hari
                return index1 < index2
            }
            return false
        }
    }

    
    private let subjectsByProdi: [String: [String]] = [
        "D3 Sistem Informasi": ["Analisis Bisnis", "Interaksi Manusia Dan Komputer", "Manajemen Proyek Sistem Informasi", "Pemrograman Web", "Pengantar Data Science", "Pengantar Teknologi", "Praktikum Interaksi Manusia Dan Komputer", "Praktikum Pemrograman Web", "Praktikum Sistem Operasi", "Sistem Informasi Manajemen", "Sistem Operasi", "Statistik dan Probabilitas", "Technopreneurship"],
        "S1 Sistem Informasi": ["Analisis Sistem Informasi", "Manajemen Proyek TI", "Business Intelligence"],
        "S1 Informatika": ["Algoritma dan Struktur Data", "Kecerdasan Buatan", "Jaringan Komputer"]
    ]
    
    func updateSubjects() {
        subjects = subjectsByProdi[selectedProgram] ?? []
    }
    
    @Published var selectedProgram: String = "Pilih Program Studi" {
        didSet {
            updateSubjects()
        }
    }
    
    
    
    init(saveUserProfileUseCase: SaveUserProfileUseCase, getLatestUserProfileUseCase: GetLatestUserProfileUseCase) {
        self.saveUserProfileUseCase = saveUserProfileUseCase
        self.getLatestUserProfileUseCase = getLatestUserProfileUseCase
        self.isOnboardingCompleted = UserDefaults.standard.bool(forKey: "isOnboardingCompleted")
        self.isInitScheduleCompleted = UserDefaults.standard.bool(forKey: "isInitScheduleCompleted")
    }

    func saveProfile() {
        isSaving = true
        do {
            try saveUserProfileUseCase.execute(
                name: name,
                prodi: selectedProgram,
                semester: selectedSemester,
                subjects: subjects // Tambahkan ini
            )
            isSaving = false
        } catch {
            self.error = IdentifiableError(error: error)
            isSaving = false
        }
    }

    func loadLatestUser() {
        do {
            savedUser = try getLatestUserProfileUseCase.execute()
            if let user = savedUser {
                subjects = user.subjects // Muat daftar mata kuliah
            }
        } catch {
            self.error = IdentifiableError(error: error)
        }
    }

    func saveProfileAndNavigate() {
        saveProfile()
        isOnboardingCompleted = true
        shouldNavigateToSchedule = true
    }
    
    func ScheduleNavigate() {
        isInitScheduleCompleted = true
        shouldNavigateToHome = true
    }

    func saveSchedule(_ schedule: ScheduleItem) {
        schedules.append(schedule)
        saveSchedulesToStorage()
    }

    private func saveSchedulesToStorage() {
        if let encoded = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(encoded, forKey: "savedSchedules")
        }
    }

    func loadSchedulesFromStorage() {
        if let savedSchedules = UserDefaults.standard.data(forKey: "savedSchedules"),
           let decodedSchedules = try? JSONDecoder().decode([ScheduleItem].self, from: savedSchedules) {
            schedules = decodedSchedules
        }
    }

    func deleteSchedule(_ schedule: ScheduleItem) {
        schedules.removeAll { $0.id == schedule.id }
        saveSchedulesToStorage()
    }

    func updateSchedule(_ updatedSchedule: ScheduleItem) {
        if let index = schedules.firstIndex(where: { $0.id == updatedSchedule.id }) {
            schedules[index] = updatedSchedule
            saveSchedulesToStorage()
        }
    }

    func schedulesForDate(_ date: Date) -> [ScheduleItem] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let dayName = daysOfWeek[weekday - 1] // Assuming daysOfWeek is ["Minggu", "Senin", "Selasa", ...]
        
        return sortedSchedules.filter { $0.day == dayName }
    }
    
    var todaySchedules: [ScheduleItem] {
        schedulesForDate(Date())
    }
    
    var tomorrowSchedules: [ScheduleItem] {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        return schedulesForDate(tomorrow)
    }
    
    let daysOfWeek = ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"]
 
    func loadMeetings(for subject: String) {
        switch subject {
        case "Analisis Bisnis":
            meetings = [
                Meeting(
                    title: "Pengenalan Analisis Proses Bisnis",
                    subject: subject,
                    description: "Pengenalan dasar tentang analisis proses bisnis",
                    initialPrompt: """
                            Anda adalah chatbot edukasi yang bertugas menjelaskan materi Pengenalan Analisis Proses Bisnis. Jelaskan materi ini secara bertahap dalam beberapa pesan singkat. Sebelum melanjutkan ke topik berikutnya, tanyakan kepada pengguna apakah mereka sudah paham atau perlu penjelasan lebih lanjut. Jika pengguna menyatakan paham, lanjutkan ke topik berikutnya. Jika tidak, berikan penjelasan tambahan atau contoh.
                            Mulailah dengan menjelaskan:
                            Tujuan mata kuliah
                            Definisi bisnis
                            Bentuk dasar kepemilikan bisnis
                            Pengelompokan kegiatan bisnis
                            Jenis kegiatan dari suatu bisnis
                            Definisi proses
                            Istilah-istilah dalam proses
                            Proses bisnis (termasuk proses inti dan proses pendukung)
                            Tingkatan pemetaan proses bisnis
                            Setiap topik harus dijelaskan dalam satu atau beberapa pesan singkat, diikuti dengan pertanyaan pemahaman sebelum melanjutkan ke topik berikutnya.

                            """,
                    initialMessage: "Selamat datang di sesi Pengenalan Analisis Proses Bisnis! Mari kita mulai dengan memahami apa itu proses bisnis dan mengapa analisisnya penting dalam dunia bisnis modern. Saya akan menjelaskan terkait analisis bisnis. Apakah anda siap?"
                ),
                Meeting(
                    title: "Komponen Proses Bisnis",
                    subject: subject,
                    description: "Membahas komponen-komponen utama dalam proses bisnis",
                    initialPrompt: "Anda adalah konsultan proses bisnis yang berpengalaman. Jelaskan secara rinci tentang komponen-komponen proses bisnis, berikan contoh nyata, dan bagaimana komponen-komponen ini berinteraksi dalam organisasi.",
                    initialMessage: "Dalam sesi ini, kita akan mempelajari komponen-komponen kunci dari proses bisnis. Dari input hingga output, setiap komponen memiliki peran penting. Apa yang ingin Anda tanyakan tentang komponen proses bisnis?"
                ),
                // Tambahkan meeting lainnya dengan prompt dan pesan awal yang unik
            ]
        case "Interaksi Manusia Dan Komputer":
            meetings = [
                Meeting(
                    title: "Pengenalan Dasar",
                    subject: subject,
                    description: "Pengenalan tentang interaksi manusia dan komputer",
                    initialPrompt: "Anda adalah pakar UX/UI dengan pengalaman luas dalam desain interaksi. Jelaskan konsep-konsep dasar IMK, prinsip-prinsip desain, dan bagaimana mereka mempengaruhi pengalaman pengguna.",
                    initialMessage: "Selamat datang di dunia Interaksi Manusia dan Komputer! Sesi ini akan memperkenalkan Anda pada konsep-konsep dasar yang membentuk cara kita berinteraksi dengan teknologi. Apa yang membuat Anda tertarik dengan IMK?"
                ),
                // Tambahkan meeting lainnya
            ]
        // Tambahkan case untuk mata kuliah lainnya
        default:
            meetings = []
        }
    }
    
    func saveMeetings() {
        if let encoded = try? JSONEncoder().encode(meetings) {
            UserDefaults.standard.set(encoded, forKey: "savedMeetings")
        }
    }
    
    func loadSavedMeetings() {
        // Muat pertemuan dari penyimpanan lokal
        if let savedMeetings = UserDefaults.standard.data(forKey: "savedMeetings"),
           let decodedMeetings = try? JSONDecoder().decode([Meeting].self, from: savedMeetings) {
            meetings = decodedMeetings
        }
    }
    
    func saveChatHistory(_ history: ChatHistory) {
        var histories = loadChatHistories()
        if let index = histories.firstIndex(where: { $0.meetingTitle == history.meetingTitle }) {
            histories[index] = history
        } else {
            histories.append(history)
        }
        
        if let encoded = try? JSONEncoder().encode(histories) {
            UserDefaults.standard.set(encoded, forKey: "chatHistories")
        }
    }
    
    func loadChatHistories() -> [ChatHistory] {
        if let savedHistories = UserDefaults.standard.data(forKey: "chatHistories"),
           let decodedHistories = try? JSONDecoder().decode([ChatHistory].self, from: savedHistories) {
            return decodedHistories
        }
        return []
    }
    
    func getChatHistory(for meetingTitle: String) -> ChatHistory? {
        return loadChatHistories().first { $0.meetingTitle == meetingTitle }
    }
}

//views
struct MainTabView: View {
    @StateObject var profileViewModel: ProfileViewModel
    
    var body: some View {
        TabView {
            ScheduleView(viewModel: profileViewModel)
                .tabItem {
                    Label("Jadwal", systemImage: "calendar")
                }
            
            MataKuliahView(profileViewModel: profileViewModel)
                .tabItem {
                    Label("Mata Kuliah", systemImage: "book.pages")
                }
        }
        .onAppear {
                 profileViewModel.loadSchedulesFromStorage()
             }
    }
}

struct HomeView: View {
    var body: some View {
        NavigationView {
            Text("Home Content")
                .navigationTitle("Home")
        }
    }
}

struct MataKuliahView: View {
    @ObservedObject var profileViewModel: ProfileViewModel
    @State private var searchText = ""
    
    var uniqueSubjects: [String] {
        Array(Set(profileViewModel.schedules.map { $0.subject })).sorted()
    }
    
    var filteredSubjects: [String] {
        if searchText.isEmpty {
            return uniqueSubjects
        } else {
            return uniqueSubjects.filter { $0.lowercased().contains(searchText.lowercased()) }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSubjects, id: \.self) { subject in
                    NavigationLink(destination: MeetingsView(viewModel: profileViewModel, subject: subject)) {
                        HStack {
                            Image(systemName: "book.pages")
                            Text(subject)
                                .font(.headline)
                        }
                    }
                }
            }
            
            .navigationTitle("Mata Kuliah")
            .searchable(text: $searchText, prompt: "Cari Mata Kuliah")
            .onAppear {
                profileViewModel.loadSchedulesFromStorage()
                profileViewModel.loadSavedMeetings()
            }
        }
    }
}

struct MeetingsView: View {
    @ObservedObject var viewModel: ProfileViewModel
    let subject: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var filteredMeetings: [Meeting] {
        let subjectMeetings = viewModel.meetings.filter { $0.subject == subject }
        if searchText.isEmpty {
            return subjectMeetings
        } else {
            return subjectMeetings.filter { meeting in
                meeting.title.localizedCaseInsensitiveContains(searchText) ||
                meeting.description.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredMeetings) { meeting in
                    NavigationLink(destination: MessageView(
                        chatController: ChatController(
                            initialPrompt: meeting.initialPrompt,
                            initialMessage: meeting.initialMessage,
                            meetingTitle: meeting.title,
                            profileViewModel: viewModel
                        ),
                        meeting: meeting
                    )) {
                        VStack(alignment: .leading) {
                            Text(meeting.title)
                                .font(.headline)
                            Text(meeting.description)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationBarTitle(subject, displayMode: .inline)
            .searchable(text: $searchText, prompt: "Cari Pertemuan")
            .onAppear {
                viewModel.loadMeetings(for: subject)
            }
        }
    }
}

struct MessageView: View {
    @ObservedObject var chatController: ChatController
    @State private var newMessage = ""
    @State private var searchText = ""
    @State private var isSearching = false
    let meeting: Meeting

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chatController.messages) { message in
                            ChatBubble(message: message, isHighlighted: isMessageHighlighted(message), searchText: searchText)
                                .padding()
                                .id(message.id)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chatController.messages) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: searchText) { _ in
                    if let firstMatch = chatController.messages.first(where: { isMessageHighlighted($0) }) {
                        withAnimation {
                            proxy.scrollTo(firstMatch.id, anchor: .center)
                        }
                    }
                }
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
            }

            VStack {
                HStack(spacing: 8) {
                    TextField("", text: $newMessage, axis: .vertical)
                        .lineLimit(5)
                        .font(.body)
                        .padding(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.gray, lineWidth: 0.5)
                        )
  
                    if !newMessage.isEmpty {
                        Button(action: sendMessage) {
                            Image(systemName: "paperplane.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32)
                                .foregroundColor(Color.orange)
                                .rotationEffect(Angle(degrees: 45))
                        }
                        .disabled(chatController.isLoading)
                    }
                }
                .padding(EdgeInsets(top: 5, leading: 21, bottom: 5, trailing: 21))
            }
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
        }
        .background(Color.gray.opacity(0.2))
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    isSearching.toggle()
                }) {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .searchable(text: $searchText, isPresented: $isSearching, prompt: "Cari pesan...")
        .onAppear {
            if chatController.messages.isEmpty {
                chatController.sendNewMessage(content: "Hai! Apa yang ingin kamu tanyakan tentang \(meeting.title)?")
            }
        }
    }

    private func isMessageHighlighted(_ message: ChatMessage) -> Bool {
        !searchText.isEmpty && message.content.lowercased().contains(searchText.lowercased())
    }

    private func sendMessage() {
        guard !newMessage.isEmpty else { return }
        chatController.sendNewMessage(content: newMessage)
        newMessage = ""
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessageId = chatController.messages.last?.id {
            proxy.scrollTo(lastMessageId, anchor: .bottom)
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let isHighlighted: Bool
    let searchText: String

    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
            }
            Text(message.content)
                .padding(10)
                .background(message.isUser ? Color.orange : Color(.white))
                .foregroundColor(message.isUser ? .black : .black)
                .cornerRadius(10)
                .overlay(
                    HighlightedText(text: message.content, searchText: searchText)
                        .padding(10)
                )
            if !message.isUser {
                Spacer()
            }
        }
    }
}

struct HighlightedText: View {
    let text: String
    let searchText: String

    var body: some View {
        Group {
            if searchText.isEmpty {
                Text(text)
            } else {
                attributedText
            }
        }
    }

    private var attributedText: some View {
        let attributedString = NSMutableAttributedString(string: text)
        let range = NSString(string: text.lowercased()).range(of: searchText.lowercased())
        if range.location != NSNotFound {
            attributedString.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.3), range: range)
        }
        return Text(AttributedString(attributedString))
    }
}


struct ProfileFormView: View {
    @StateObject private var viewModel: ProfileViewModel
    @State private var showingSavedData = false

    
    init(viewModel: ProfileViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        HStack {
                            Text("Nama")
                                .frame(maxWidth: 100, alignment: .leading)
                            TextFieldClear(placeholder: "Nama Anda", text: $viewModel.name, keyboardType: .default, onClear: {
                                viewModel.name = ""
                            })
                        }
                    }
                    Section {
                        NavigationLink(destination: ProgramsView(selectedProgram: $viewModel.selectedProgram)) {
                            Text(viewModel.selectedProgram)
                                .foregroundStyle(.orange)
                        }
                        
                        NavigationLink(destination: SemesterView(selectedSemester: $viewModel.selectedSemester)) {
                            Text(viewModel.selectedSemester)
                                .foregroundStyle(.orange)
                        }
                    }
                    Section {
                        Button("Lihat Data Tersimpan") {
                            viewModel.loadLatestUser()
                            showingSavedData = true
                        }
                    }
                }
                VStack {
                    Spacer()
                    ButtonFill(title: "Lanjutkan", action: {
                        viewModel.saveProfileAndNavigate()
                    },
                               backgroundColor: isFormValid ? .orange : .gray
                    )
                    .disabled(viewModel.isSaving)
                    .disabled(!isFormValid)
                    .padding()
                }
            }
            .navigationBarTitle("Profile", displayMode: .large)
            .navigationDestination(isPresented: $viewModel.shouldNavigateToSchedule) {
                InitScheduleView(viewModel: viewModel)
                    .navigationBarBackButtonHidden(true)
            }
            .alert(item: $viewModel.error) { identifiableError in
                Alert(
                    title: Text("Error"),
                    message: Text(identifiableError.error.localizedDescription)
                )
            }
            .sheet(isPresented: $showingSavedData) {
                if let user = viewModel.savedUser {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Data Tersimpan:")
                            .font(.headline)
                        Text("Nama: \(user.onboarding.name)")
                        Text("Program Studi: \(user.onboarding.prodi)")
                        Text("Semester: \(user.onboarding.semester)")
                    }
                    .padding()
                } else {
                    Text("Tidak ada data tersimpan")
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        !viewModel.name.isEmpty &&
        !viewModel.selectedProgram.contains("Pilih Program Studi") &&
        !viewModel.selectedSemester.contains("Pilih Semester") &&
        !viewModel.isSaving
    }

}

struct SemesterView: View {
    let semesters: [Int:String] = [
        1: "Semester 1",
        2: "Semester 2",
        3: "Semester 3",
        4: "Semester 4",
        5: "Semester 5",
        6: "Semester 6",
        7: "Semester 7",
        8: "Semester 8",
    ]
    @Binding var selectedSemester: String
    @Environment(\.presentationMode) var presentationMode
    @State private var searchText = ""

    
    var filteredSemesters: [(key: Int, value: String)] {
        if searchText.isEmpty {
            return Array(semesters.sorted(by: { $0.key < $1.key }))
        } else {
            return semesters.filter { $0.value.lowercased().contains(searchText.lowercased()) }
                .sorted(by: { $0.key < $1.key })
        }
    }


    var body: some View {
        Form {
            ForEach(filteredSemesters, id: \.key) { key, value in
                Button(action: {
                    selectedSemester = value
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Text(value)
                        .foregroundColor(.primary)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Cari semester")
        .navigationBarTitle("Pilih Semester", displayMode: .inline)
    }
}

struct ProgramsView: View {
    let programs: [Int:String] = [
        1: "D3 Sistem Informasi",
        2: "S1 Sistem Informasi",
        3: "S1 Informatika",
    ]
    @Binding var selectedProgram: String
    @Environment(\.presentationMode) var presentationMode
    @State private var searchText = ""


    var body: some View {
        Form {
            ForEach(searchResults, id: \.key) { key, value in
                Button(action: {
                    selectedProgram = value
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Text(value)
                        .foregroundColor(.primary)
                }
            }
        }
        .navigationBarTitle("Pilih Program Studi", displayMode: .inline)
        .searchable(text: $searchText, prompt: "Cari program studi")

    }
    var searchResults: [(key: Int, value: String)] {
        if searchText.isEmpty {
            return programs.sorted { $0.key < $1.key }
        } else {
            return programs.filter { $0.value.lowercased().contains(searchText.lowercased()) }
                .sorted { $0.key < $1.key }
        }
    }

}

struct InitScheduleView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var isAddScheduleViewPresented = false
    @State private var editingSchedule: ScheduleItem?


    var daysWithSchedules: [String] {
        return viewModel.dayOrder.filter { day in
            viewModel.sortedSchedules.contains { $0.day == day }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.schedules.isEmpty {
                    VStack {
                        Spacer()
                        Text("Untuk menambahkan jadwal kelas Anda, silakan klik tombol tambah (+) yang terletak di sudut kanan atas.")
                            .font(.callout)
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(daysWithSchedules, id: \.self) { day in
                            Section(header: Text(day).textCase(.uppercase).foregroundStyle(.orange)) {
                                ForEach(viewModel.sortedSchedules.filter { $0.day == day }) { schedule in
                                    ScheduleItemView(schedule: schedule,
                                        onDelete: {
                                            viewModel.deleteSchedule(schedule)
                                        },
                                        onEdit: {
                                            editingSchedule = schedule
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading:
                Text("Jadwal")
                    .font(.headline)
                    .foregroundColor(.primary)
            )
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            isAddScheduleViewPresented = true
                        }, label: {
                            Image(systemName: "plus")
                                .font(.subheadline)
                        })
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Spacer()
                        Button(action: {
                            viewModel.ScheduleNavigate()
                        }) {
                            Text("Selesai")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .disabled(!isScheduleAdded)
                    }
                }
            }
            .sheet(isPresented: $isAddScheduleViewPresented) {
                AddScheduleView(viewModel: viewModel)
            }
            .sheet(item: $editingSchedule) { schedule in
                EditScheduleView(viewModel: viewModel, schedule: schedule)
            }
            .onAppear {
                viewModel.loadSchedulesFromStorage()
            }
            .navigationDestination(isPresented: $viewModel.shouldNavigateToHome) {
                ScheduleView(viewModel: viewModel)
                    .navigationBarBackButtonHidden(true)
            }
        }
    }
    private var isScheduleAdded: Bool {
        !viewModel.schedules.isEmpty
    }
}

struct ScheduleItemView: View {
    let schedule: ScheduleItem
    let onDelete: () -> Void
    let onEdit: () -> Void

    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(schedule.subject)
                    .font(.headline)
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                    Text(schedule.location)
                }
                .font(.subheadline)
                .foregroundColor(.gray)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(formatTime(schedule.startTime))
                    .font(.subheadline)
                Text(formatTime(schedule.endTime))
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Hapus", systemImage: "trash")
            }
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }

    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct AddScheduleView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ProfileViewModel
    @State private var selectedSubject: String = ""
    @State private var selectedLocation: String = ""
    @State private var selectedDay = 0
    @State private var startTime = Date()
    @State private var endTime = Date()


    
    let daysOfWeek = ["Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink(destination: SubjectPickerView(viewModel: viewModel, selectedSubject: $selectedSubject)) {
                              Text(selectedSubject.isEmpty ? "Pilih Mata Kuliah" : selectedSubject)
                                  .foregroundStyle(.orange)
                          }
                }
                Section {
                    Picker("Hari", selection: $selectedDay) {
                        ForEach(0..<daysOfWeek.count, id: \.self) { index in
                            Text(daysOfWeek[index]).tag(index)
                        }
                    }
                }
                Section {
                    DatePicker("Jam Mulai", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Jam Selesai", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                Section {
                    NavigationLink(destination: RoomLocationView(selectedLocation: $selectedLocation)) {
                        Text(selectedLocation.isEmpty ? "Pilih Ruang" : selectedLocation)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationBarTitle("Tambah", displayMode: .inline)
            .navigationBarItems(trailing: Button("Simpan") {
                saveSchedule()
            }
                .disabled(!isFormValid))
            .navigationBarItems(leading: Button("Batal") {
                dismiss()
            })
        }
        
    }
    private func saveSchedule() {
        let newSchedule = ScheduleItem(
            id: UUID(),
            subject: selectedSubject,
            location: selectedLocation,
            day: daysOfWeek[selectedDay],
            startTime: startTime,
            endTime: endTime
        )
        viewModel.saveSchedule(newSchedule)
        dismiss()
    }
    
    private var isFormValid: Bool {
        !selectedSubject.isEmpty &&
        !selectedLocation.isEmpty
    }

}

struct EditScheduleView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editedSchedule: ScheduleItem

    init(viewModel: ProfileViewModel, schedule: ScheduleItem) {
        self.viewModel = viewModel
        _editedSchedule = State(initialValue: schedule)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink(destination: SubjectPickerView(viewModel: viewModel, selectedSubject: $editedSchedule.subject)) {
                        Text( editedSchedule.subject)
                                  .foregroundStyle(.orange)
                          }
                    NavigationLink(destination: RoomLocationView(selectedLocation: $editedSchedule.location)) {
                        Text( editedSchedule.location)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Picker("Hari", selection: $editedSchedule.day) {
                        ForEach(viewModel.dayOrder, id: \.self) { day in
                            Text(day).tag(day)
                        }
                    }
                }
                Section {
                    DatePicker("Jam Mulai", selection: $editedSchedule.startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Jam Selesai", selection: $editedSchedule.endTime, displayedComponents: .hourAndMinute)
                }
            }
            .navigationBarTitle("Edit", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Batal") { dismiss() },
                trailing: Button("Simpan") {
                    viewModel.updateSchedule(editedSchedule)
                    dismiss()
                }
            )
        }
    }
}

struct SubjectPickerView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @Binding var selectedSubject: String
    @State private var searchText = ""
    @Environment(\.presentationMode) var presentationMode

    var filteredSubjects: [String] {
        if searchText.isEmpty {
            return viewModel.subjects
        } else {
            return viewModel.subjects.filter { $0.lowercased().contains(searchText.lowercased()) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSubjects, id: \.self) { subject in
                    Button(action: {
                        selectedSubject = subject
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text(subject)
                            .foregroundColor(.black)
                    }
                }
            }
            .navigationBarTitle("Pilih Mata Kuliah", displayMode: .large)
            .searchable(text: $searchText, prompt: "Cari mata kuliah")
        }
    }
}
struct RoomLocationView: View {
    let subjects: [Int:String] = [
        1: "FIK-201",
        2: "FIKLAB-201",
        3: "FIKLAB-202",
        4: "FIKLAB-203",
        5: "FIKLAB-301",
        6: "FIKLAB-302",
        7: "FIKLAB-303",
        8: "FIKLAB-401",
        9: "FIKLAB-402",
        10: "FIKLAB-403",
    ]
    @State private var searchText = ""
    @Binding var selectedLocation: String
    @Environment(\.presentationMode) var presentationMode


    var filteredSubjects: [(key: Int, value: String)] {
        if searchText.isEmpty {
            return Array(subjects.sorted(by: { $0.key < $1.key }))
        } else {
            return subjects.filter { $0.value.lowercased().contains(searchText.lowercased()) }
                .sorted(by: { $0.key < $1.key })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSubjects, id: \.key) { key, value in
                    Button(action: {
                        selectedLocation = value
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text(value)
                            .foregroundColor(.black)
                    }
                }
            }
            .navigationBarTitle("Ruang", displayMode: .large)
            .searchable(text: $searchText, prompt: "Cari")
        }
    }
}

struct ScheduleView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var selectedSegment = 1
    @State private var isAddScheduleViewPresented = false
    @State private var editingSchedule: ScheduleItem?
    
    var body: some View {
        NavigationStack {
            VStack {
                if selectedSegment == 0 {
                    AllSchedulesView(viewModel: viewModel)
                } else {
                    ShortScheduleView(viewModel: viewModel)
                }
            }
            .navigationTitle("Jadwal")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $selectedSegment) {
                        Text("Singkat").tag(1)
                        Text("Semua").tag(0)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Spacer()
                        Button(action: {
                            isAddScheduleViewPresented = true
                        }) {
                            Image(systemName: "plus")
                        }
                    }

                }
            }
        }
        .sheet(isPresented: $isAddScheduleViewPresented) {
            AddScheduleView(viewModel: viewModel)
        }
        .sheet(item: $editingSchedule) { schedule in
            EditScheduleView(viewModel: viewModel, schedule: schedule)
        }
        .onAppear {
            viewModel.loadSchedulesFromStorage()
        }
    }
}

struct AllSchedulesView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var isAddScheduleViewPresented = false
    @State private var editingSchedule: ScheduleItem?
    
    var daysWithSchedules: [String] {
        return viewModel.dayOrder.filter { day in
            viewModel.sortedSchedules.contains { $0.day == day }
        }
    }
    
    var body: some View {
        ZStack {
            if viewModel.schedules.isEmpty {
                VStack {
                    Spacer()
                    Text("Untuk menambahkan jadwal kelas Anda, silakan klik tombol tambah (+) yang terletak di sudut kanan atas.")
                        .font(.callout)
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
            } else {
                List {
                    ForEach(daysWithSchedules, id: \.self) { day in
                        Section(header: Text(day).textCase(.uppercase).foregroundStyle(.orange)) {
                            ForEach(viewModel.sortedSchedules.filter { $0.day == day }) { schedule in
                                ScheduleItemView(schedule: schedule,
                                                 onDelete: { viewModel.deleteSchedule(schedule) },
                                                 onEdit: { editingSchedule = schedule })
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $isAddScheduleViewPresented) {
            AddScheduleView(viewModel: viewModel)
        }
        .sheet(item: $editingSchedule) { schedule in
            EditScheduleView(viewModel: viewModel, schedule: schedule)
        }
        .onAppear {
            viewModel.loadSchedulesFromStorage()
        }
    }
}

struct ShortScheduleView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var editingSchedule: ScheduleItem?
    
    var body: some View {
        VStack(alignment: .leading) {
            List {
                Section(header: Text(formatSectionHeader(for: Date())).foregroundStyle(.orange)) {
                    if viewModel.todaySchedules.isEmpty {
                        Text("Tidak ada jadwal")
                            .font(.subheadline)
                    } else {
                        ForEach(viewModel.todaySchedules) { schedule in
                            ScheduleItemView(schedule: schedule,
                                             onDelete: { viewModel.deleteSchedule(schedule) },
                                             onEdit: { editingSchedule = schedule })
                        }
                    }
                }
                Section(header: Text(formatSectionHeader(for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)).foregroundStyle(.orange)) {
                    if viewModel.tomorrowSchedules.isEmpty {
                        Text("Tidak ada jadwal")
                            .font(.subheadline)
                    } else {
                        ForEach(viewModel.tomorrowSchedules) { schedule in
                            ScheduleItemView(schedule: schedule,
                                             onDelete: { viewModel.deleteSchedule(schedule) },
                                             onEdit: { editingSchedule = schedule })
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .sheet(item: $editingSchedule) { schedule in
            EditScheduleView(viewModel: viewModel, schedule: schedule)
        }
    }
    
    private func formatSectionHeader(for date: Date) -> String {
        let dayName = viewModel.dayName(for: date)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMMM"
        let dateString = dateFormatter.string(from: date)
        
        if Calendar.current.isDateInToday(date) {
            return "HARI INI — \(dayName), \(dateString)"
        } else {
            return "BESOK — \(dayName), \(dateString)"
        }
    }
}

struct TomorrowScheduleView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @State private var editingSchedule: ScheduleItem?
    
    var body: some View {
        VStack(alignment: .leading) {
            
            if viewModel.tomorrowSchedules.isEmpty {
                VStack {
                    Spacer()
                    Text("Tidak ada jadwal untuk besok")
                        .foregroundColor(.gray)
                        .padding()
                    Spacer()
                }
            } else {
                List {
                    Section(header: Text(viewModel.dayName(for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!).uppercased()).textCase(.uppercase).foregroundStyle(.orange)) {
                        ForEach(viewModel.tomorrowSchedules) { schedule in
                            ScheduleItemView(schedule: schedule,
                                    onDelete: { viewModel.deleteSchedule(schedule) },
                                    onEdit: { editingSchedule = schedule })
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $editingSchedule) { schedule in
            EditScheduleView(viewModel: viewModel, schedule: schedule)
        }
    }
}


